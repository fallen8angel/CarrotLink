# ExecuTorch Local AAR Drop-In

Place a backend-specific `executorch.aar` here when testing local Android runtime builds.

Expected path:

- `android/app/libs/executorch.aar`

For Qualcomm/QNN bring-up, the AAR alone may not be enough. The APK also needs QNN runtime
native libraries such as `libQnnHtp.so`, `libQnnSystem.so`, or other `libQnn*.so` files,
as described in the official Qualcomm backend documentation.

Build with:

```powershell
cd E:\Carrot\CarrotLink\android
.\gradlew.bat :app:assembleDebug
```

If you need to force the old Maven path:

```powershell
.\gradlew.bat :app:assembleDebug -PuseLocalAar=false
```

If a local Qualcomm/QNN SDK is available, the app will also auto-package selected runtime libs
and skel assets during build.

Lookup order:

- Gradle property: `-PqnnSdkRoot=...`
- Env var: `QNN_SDK_ROOT`
- Local default: `E:\Carrot\yolo\2.32.6.250402`

Current auto-packaged files:

- `libQnnHtp.so`
- `libQnnSystem.so`
- `libQnnHtpPrepare.so`
- `libQnnHtpNetRunExtensions.so`
- `libQnnHtpV68Stub.so`
- `libQnnHtpV69Stub.so`
- `libQnnHtpV73Stub.so`
- `libQnnHtpV75Stub.so`
- `libQnnHtpV79Stub.so`
- `libQnnHtpV68Skel.so`
- `libQnnHtpV69Skel.so`
- `libQnnHtpV73Skel.so`
- `libQnnHtpV75Skel.so`
- `libQnnHtpV79Skel.so`

Reference:

- [Using ExecuTorch on Android](https://docs.pytorch.org/executorch/stable/using-executorch-android.html)
- [Qualcomm AI Engine Backend](https://docs.pytorch.org/executorch/stable/backends-qualcomm.html)
