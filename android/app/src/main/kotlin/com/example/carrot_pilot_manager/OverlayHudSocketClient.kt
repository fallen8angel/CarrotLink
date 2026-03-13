package com.example.carrot_pilot_manager

import android.os.Handler
import android.os.SystemClock
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.TimeUnit

internal class OverlayHudSocketClient(
    private val mainHandler: Handler,
) {
  var isConnected: Boolean = false
    private set

  var lastMessageAt: Long = 0L
    private set

  private var wsClient: OkHttpClient? = null
  private var webSocket: WebSocket? = null
  private var reconnectRunnable: Runnable? = null
  private var socketCandidateIndex = 0

  fun resetCandidates() {
    socketCandidateIndex = 0
  }

  fun hasReconnectScheduled(): Boolean = reconnectRunnable != null

  fun connect(
      host: String,
      force: Boolean,
      hasFreshSemanticSnapshot: () -> Boolean,
      onStatus: (String, String) -> Unit,
      onMessage: (String) -> Unit,
      requestReconnect: () -> Unit,
  ) {
    if (host.isBlank()) return
    if (hasFreshSemanticSnapshot()) {
      onStatus("연결됨 · $host", "연결됨: $host")
      return
    }
    if (!force && isConnected && webSocket != null) return

    cancelReconnect()
    disconnect(shutdownClient = false)

    if (wsClient == null) {
      wsClient = OkHttpClient.Builder()
          .pingInterval(20, TimeUnit.SECONDS)
          .retryOnConnectionFailure(true)
          .build()
    }

    onStatus("연결 중", "연결 중: $host")

    val request = Request.Builder()
        .url(currentWebsocketUrl(host))
        .build()

    webSocket = wsClient?.newWebSocket(
        request,
        object : WebSocketListener() {
          override fun onOpen(webSocket: WebSocket, response: Response) {
            isConnected = true
            lastMessageAt = SystemClock.elapsedRealtime()
            mainHandler.post {
              onStatus("연결됨", "연결됨: $host")
            }
          }

          override fun onMessage(webSocket: WebSocket, text: String) {
            lastMessageAt = SystemClock.elapsedRealtime()
            onMessage(text)
          }

          override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            isConnected = false
            if (hasFreshSemanticSnapshot()) return
            advanceSocketCandidate(host)
            mainHandler.post {
              onStatus("끊김, 재연결", "끊김, 재연결")
            }
            requestReconnect()
          }

          override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            isConnected = false
            if (hasFreshSemanticSnapshot()) return
            advanceSocketCandidate(host)
            mainHandler.post {
              onStatus("연결 종료, 재시도", "연결 종료, 재시도")
            }
            requestReconnect()
          }
        },
    )
  }

  fun scheduleReconnect(
      host: String?,
      destroyed: Boolean,
      reconnectDelayMs: Long,
      onConnect: () -> Unit,
  ) {
    if (destroyed) return
    if (host.isNullOrBlank()) return
    if (reconnectRunnable != null) return

    reconnectRunnable = Runnable {
      reconnectRunnable = null
      if (!destroyed) {
        onConnect()
      }
    }
    mainHandler.postDelayed(reconnectRunnable!!, reconnectDelayMs)
  }

  fun cancelReconnect() {
    reconnectRunnable?.let { mainHandler.removeCallbacks(it) }
    reconnectRunnable = null
  }

  fun disconnect(shutdownClient: Boolean) {
    try {
      webSocket?.cancel()
    } catch (_: Throwable) {
    }
    webSocket = null
    isConnected = false

    if (shutdownClient) {
      wsClient?.dispatcher?.executorService?.shutdown()
      wsClient?.connectionPool?.evictAll()
      wsClient = null
    }
  }

  private fun currentWebsocketUrl(host: String): String {
    val candidates = websocketCandidates(host)
    if (candidates.isEmpty()) {
      return "ws://$host:7000/ws/carstate"
    }
    socketCandidateIndex = socketCandidateIndex.coerceIn(0, candidates.lastIndex)
    return candidates[socketCandidateIndex]
  }

  private fun advanceSocketCandidate(host: String) {
    val size = websocketCandidates(host).size
    if (size <= 1) return
    socketCandidateIndex = (socketCandidateIndex + 1) % size
  }

  private fun websocketCandidates(host: String): List<String> {
    return listOf(
        "ws://$host:7766/ws/hud",
        "ws://$host:7000/ws/carstate",
    )
  }
}
