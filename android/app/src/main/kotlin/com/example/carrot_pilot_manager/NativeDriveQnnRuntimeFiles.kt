package com.example.carrot_pilot_manager

import android.content.Context
import android.system.Os
import java.io.File
import java.util.zip.ZipFile

internal data class NativeDriveQnnPreparedRuntime(
    val runtimeDir: String? = null,
    val assetFiles: List<String> = emptyList(),
    val envConfigured: Boolean = false,
    val reason: String? = null,
)

internal object NativeDriveQnnRuntimeFiles {
  private const val assetRoot = "qnn/skels"
  private const val extractedDirName = "carrotlink_qnn_runtime"
  @Volatile private var cachedNativeLibSignature: String? = null
  @Volatile private var cachedNativeLibs: List<String> = emptyList()

  fun listPackagedSkels(context: Context): List<String> {
    return runCatching { listAssetFiles(context, assetRoot) }.getOrDefault(emptyList()).sorted()
  }

  fun listPackagedNativeLibs(context: Context): List<String> {
    val applicationInfo = context.applicationInfo
    val signature =
        buildString {
          append(applicationInfo.nativeLibraryDir ?: "")
          append('|')
          append(applicationInfo.sourceDir ?: "")
          append('|')
          append(applicationInfo.splitSourceDirs?.joinToString("|") ?: "")
        }
    val cachedSignature = cachedNativeLibSignature
    if (cachedSignature == signature) {
      return cachedNativeLibs
    }

    val libs =
        linkedSetOf<String>().apply {
          addAll(listNativeLibDirFiles(applicationInfo.nativeLibraryDir))
          addAll(listApkNativeLibFiles(applicationInfo.sourceDir))
          applicationInfo.splitSourceDirs?.forEach { splitPath ->
            addAll(listApkNativeLibFiles(splitPath))
          }
        }
    val resolved = libs.sorted()
    cachedNativeLibSignature = signature
    cachedNativeLibs = resolved
    return resolved
  }

  fun prepare(
      context: Context,
      nativeLibDir: String?,
  ): NativeDriveQnnPreparedRuntime {
    val assetFiles = listPackagedSkels(context)
    if (assetFiles.isEmpty()) {
      return NativeDriveQnnPreparedRuntime(
          assetFiles = emptyList(),
          envConfigured = false,
          reason = "qnn_skel_assets_missing",
      )
    }

    val runtimeDir =
        runCatching {
              File(context.noBackupFilesDir, extractedDirName).apply { mkdirs() }
            }
            .getOrNull()
            ?: return NativeDriveQnnPreparedRuntime(
                assetFiles = assetFiles,
                envConfigured = false,
                reason = "qnn_runtime_dir_unavailable",
            )

    val extracted =
        runCatching {
              val expectedFiles = assetFiles.toSet()
              runtimeDir.listFiles()?.forEach { existing ->
                if (existing.isFile && existing.name.endsWith(".so") && existing.name !in expectedFiles) {
                  existing.delete()
                }
              }
              assetFiles.forEach { fileName ->
                context.assets.open("$assetRoot/$fileName").use { input ->
                  val assetBytes = input.readBytes()
                  val outFile = File(runtimeDir, fileName)
                  val shouldRewrite =
                      !outFile.exists() ||
                          outFile.length() != assetBytes.size.toLong() ||
                          !runCatching { outFile.readBytes().contentEquals(assetBytes) }.getOrDefault(false)
                  if (shouldRewrite) {
                    outFile.outputStream().use { output -> output.write(assetBytes) }
                  }
                }
              }
              assetFiles
            }
            .getOrElse {
              return NativeDriveQnnPreparedRuntime(
                  runtimeDir = runtimeDir.absolutePath,
                  assetFiles = assetFiles,
                  envConfigured = false,
                  reason = "qnn_skel_extract_failed",
              )
            }

    val adspLibraryPath =
        listOf(
                runtimeDir.absolutePath,
                "/vendor/dsp/cdsp",
                "/vendor/lib/rfsa/adsp",
                "/system/lib/rfsa/adsp",
                "/dsp",
            )
            .joinToString(";")
    val ldLibraryPath =
        buildList {
              if (!nativeLibDir.isNullOrBlank()) add(nativeLibDir)
              add(runtimeDir.absolutePath)
              add("/vendor/dsp/cdsp")
              add("/vendor/lib64")
            }
            .joinToString(":")

    return try {
      Os.setenv("ADSP_LIBRARY_PATH", adspLibraryPath, true)
      Os.setenv("LD_LIBRARY_PATH", ldLibraryPath, true)
      NativeDriveQnnPreparedRuntime(
          runtimeDir = runtimeDir.absolutePath,
          assetFiles = extracted,
          envConfigured = true,
      )
    } catch (_: Throwable) {
      NativeDriveQnnPreparedRuntime(
          runtimeDir = runtimeDir.absolutePath,
          assetFiles = extracted,
          envConfigured = false,
          reason = "qnn_env_config_failed",
      )
    }
  }

  private fun listAssetFiles(context: Context, path: String): List<String> {
    val children = context.assets.list(path)?.sorted().orEmpty()
    if (children.isEmpty()) {
      return if (path == assetRoot) emptyList() else listOf(path.substringAfter("$assetRoot/"))
    }
    return children.flatMap { child ->
      listAssetFiles(context, "$path/$child")
    }
  }

  private fun listNativeLibDirFiles(path: String?): List<String> {
    return runCatching {
          path
              ?.takeIf { it.isNotBlank() }
              ?.let { File(it) }
              ?.listFiles()
              ?.map { it.name }
              ?.filter(::isQnnRelevantLibName)
              ?.sorted()
              ?: emptyList()
        }
        .getOrDefault(emptyList())
  }

  private fun listApkNativeLibFiles(apkPath: String?): List<String> {
    if (apkPath.isNullOrBlank()) return emptyList()
    return runCatching {
          ZipFile(apkPath).use { zip ->
            zip.entries().asSequence()
                .map { it.name }
                .filter { it.startsWith("lib/") && it.endsWith(".so") }
                .mapNotNull { it.substringAfterLast('/').takeIf(::isQnnRelevantLibName) }
                .toList()
          }
        }
        .getOrDefault(emptyList())
  }

  private fun isQnnRelevantLibName(name: String): Boolean {
    val lower = name.lowercase()
    return lower.startsWith("libqnn") || lower == "libqnn_executorch_backend.so"
  }
}
