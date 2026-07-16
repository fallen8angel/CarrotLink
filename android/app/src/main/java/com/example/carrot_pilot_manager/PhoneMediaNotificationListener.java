package com.example.carrot_pilot_manager;

import android.app.Notification;
import android.content.ComponentName;
import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.Icon;
import android.media.MediaDescription;
import android.media.MediaMetadata;
import android.media.session.MediaController;
import android.media.session.MediaSession;
import android.media.session.MediaSessionManager;
import android.media.session.PlaybackState;
import android.net.DhcpInfo;
import android.net.Uri;
import android.net.wifi.WifiManager;
import android.os.Bundle;
import android.os.Parcelable;
import android.os.SystemClock;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;
import android.util.Base64;
import android.util.Log;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.URL;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.json.JSONObject;

/* JADX INFO: loaded from: classes3.dex */
public class PhoneMediaNotificationListener extends NotificationListenerService {
    private static final int ART_MAX_PX = 256;
    private static final int ART_QUALITY = 86;
    private static final long ART_REFRESH_INTERVAL_MS = 5 * 60 * 1000L;
    private static final String PREFS = "carrot_media_bridge";
    private static final String PREF_HOST = "carrot_host";
    private static final String PREF_URL = "sidecar_url";
    private static final long PUBLISH_INTERVAL_SECONDS = 2;
    private static final long REBIND_DELAY_SECONDS = 2;
    private static final String TAG = "CarrotMediaBridge";
    private static final int TEXT_MAX_CODEPOINTS = 160;
    private static final int HEALTH_TIMEOUT_MS = 1500;
    private static final int POST_CONNECT_TIMEOUT_MS = 2500;
    private static final int POST_READ_TIMEOUT_MS = 5000;
    private static final int POST_FAILURES_BEFORE_REDISCOVERY = 3;
    private Bitmap cachedArtBitmap;
    private volatile boolean periodicStarted;
    private static final String[] PORTS = {"7000", "7766"};
    private static final Pattern IPV4 = Pattern.compile("(?<![0-9])((?:[0-9]{1,3}\\.){3}[0-9]{1,3})(?::([0-9]{2,5}))?");
    private static volatile String preferredHost = "";
    private final ScheduledExecutorService executor = Executors.newSingleThreadScheduledExecutor();
    private final ExecutorService artworkExecutor = Executors.newSingleThreadExecutor();
    private final AtomicBoolean publishing = new AtomicBoolean(false);
    private final AtomicBoolean artworkPublishing = new AtomicBoolean(false);
    private volatile String activeSidecarUrl = "";
    private volatile MediaInfo cachedArtworkMedia;
    private volatile String lastPublishedArtKey = "";
    private volatile long lastPublishedArtElapsedMs;
    private volatile int consecutivePostFailures;
    private String cachedArtUri = "";

    public static void setSidecarHost(Context context, String str) {
        if (context == null || str == null) {
            return;
        }
        String strTrim = normalizeHost(str);
        if (strTrim.isEmpty()) {
            return;
        }
        preferredHost = strTrim;
        SharedPreferences preferences = context.getSharedPreferences(PREFS, 0);
        SharedPreferences.Editor editor = preferences.edit().putString(PREF_HOST, strTrim);
        String rememberedUrl = preferences.getString(PREF_URL, "");
        String rememberedHost = hostFromUrl(rememberedUrl);
        if (!rememberedHost.isEmpty() && !rememberedHost.equalsIgnoreCase(strTrim)) {
            editor.remove(PREF_URL);
        }
        editor.apply();
    }

    private static String normalizeHost(String value) {
        if (value == null) {
            return "";
        }
        String candidate = value.trim();
        if (candidate.isEmpty()) {
            return "";
        }
        String parsedHost = hostFromUrl(candidate);
        if (!parsedHost.isEmpty()) {
            return parsedHost;
        }
        int schemeIndex = candidate.indexOf("://");
        if (schemeIndex >= 0) {
            candidate = candidate.substring(schemeIndex + 3);
        }
        int slashIndex = candidate.indexOf('/');
        if (slashIndex >= 0) {
            candidate = candidate.substring(0, slashIndex);
        }
        int colonIndex = candidate.lastIndexOf(':');
        if (colonIndex > 0 && candidate.indexOf(':') == colonIndex) {
            candidate = candidate.substring(0, colonIndex);
        }
        return candidate.trim();
    }

    private static String hostFromUrl(String value) {
        if (value == null || value.trim().isEmpty()) {
            return "";
        }
        try {
            String candidate = value.trim();
            if (!candidate.contains("://")) {
                candidate = "http://" + candidate;
            } else if (candidate.startsWith("ws://")) {
                candidate = "http://" + candidate.substring(5);
            } else if (candidate.startsWith("wss://")) {
                candidate = "https://" + candidate.substring(6);
            }
            String host = new URL(candidate).getHost();
            return host == null ? "" : host.trim();
        } catch (Exception ignored) {
            return "";
        }
    }

    @Override // android.app.Service
    public void onCreate() {
        super.onCreate();
        ensurePeriodicPublisher();
    }

    @Override // android.service.notification.NotificationListenerService
    public void onListenerConnected() {
        super.onListenerConnected();
        ensurePeriodicPublisher();
        schedulePublish();
        Log.i(TAG, "notification listener connected");
    }

    @Override // android.service.notification.NotificationListenerService
    public void onListenerDisconnected() {
        super.onListenerDisconnected();
        this.activeSidecarUrl = "";
        this.lastPublishedArtKey = "";
        this.lastPublishedArtElapsedMs = 0L;
        Log.w(TAG, "notification listener disconnected; requesting rebind");
        try {
            this.executor.schedule(new Runnable() {
                @Override
                public void run() {
                    try {
                        NotificationListenerService.requestRebind(new ComponentName(
                                PhoneMediaNotificationListener.this,
                                PhoneMediaNotificationListener.class));
                    } catch (Exception e) {
                        Log.w(TAG, "notification listener rebind failed", e);
                    }
                }
            }, REBIND_DELAY_SECONDS, TimeUnit.SECONDS);
        } catch (Exception e) {
            Log.w(TAG, "notification listener rebind scheduling failed", e);
        }
    }

    private synchronized void ensurePeriodicPublisher() {
        if (this.periodicStarted || this.executor.isShutdown()) {
            return;
        }
        this.periodicStarted = true;
        this.executor.scheduleWithFixedDelay(new Runnable() { // from class: com.example.carrot_pilot_manager.PhoneMediaNotificationListener.1
            @Override // java.lang.Runnable
            public void run() {
                PhoneMediaNotificationListener.this.schedulePublish();
            }
        }, PUBLISH_INTERVAL_SECONDS, PUBLISH_INTERVAL_SECONDS, TimeUnit.SECONDS);
    }

    @Override // android.service.notification.NotificationListenerService
    public void onNotificationPosted(StatusBarNotification statusBarNotification) {
        schedulePublish();
    }

    @Override // android.service.notification.NotificationListenerService
    public void onNotificationRemoved(StatusBarNotification statusBarNotification) {
        schedulePublish();
    }

    @Override // android.service.notification.NotificationListenerService, android.app.Service
    public void onDestroy() {
        this.executor.shutdownNow();
        this.artworkExecutor.shutdownNow();
        super.onDestroy();
    }

    /* JADX INFO: Access modifiers changed from: private */
    public void schedulePublish() {
        if (this.publishing.compareAndSet(false, true)) {
            this.executor.execute(new Runnable() { // from class: com.example.carrot_pilot_manager.PhoneMediaNotificationListener.2
                @Override // java.lang.Runnable
                public void run() {
                    try {
                        try {
                            PhoneMediaNotificationListener.this.publishNow();
                        } catch (Exception e5) {
                            Log.w(PhoneMediaNotificationListener.TAG, "publish failed", e5);
                        }
                    } finally {
                        PhoneMediaNotificationListener.this.publishing.set(false);
                    }
                }
            });
        }
    }

    /* JADX INFO: Access modifiers changed from: private */
    public void publishNow() throws Exception {
        String strFindSidecarUrl = findSidecarUrl();
        if (strFindSidecarUrl.isEmpty()) {
            Log.d(TAG, "sidecar unavailable; retrying discovery");
            return;
        }
        MediaInfo mediaInfo = readMediaInfo(false);
        MediaInfo cachedMedia = this.cachedArtworkMedia;
        if (!mediaInfo.hasArt() && cachedMedia != null && cachedMedia.hasArt()
                && sameMediaItem(mediaInfo, cachedMedia)) {
            mediaInfo.copyArtFrom(cachedMedia);
        }
        if (!mediaInfo.hasDisplayData()) {
            Log.d(TAG, "no displayable media; keeping last comma snapshot until stale");
            return;
        }
        MediaInfo payload = heartbeatPayload(mediaInfo);
        try {
            postJson(strFindSidecarUrl + "/phone/media", payload.toJson().toString());
            this.consecutivePostFailures = 0;
            if (payload.hasArt()) {
                this.lastPublishedArtKey = artworkKey(mediaInfo);
                this.lastPublishedArtElapsedMs = SystemClock.elapsedRealtime();
            }
            Log.d(TAG, "published media artBytes=" + payload.artByteCount + " artSource=" + payload.artSource + " titleChars=" + payload.title.length());
            if (mediaInfo.hasArt()) {
                this.cachedArtworkMedia = mediaInfo;
            } else {
                scheduleArtworkPublish(strFindSidecarUrl, mediaInfo);
            }
        } catch (Exception e5) {
            this.lastPublishedArtKey = "";
            this.lastPublishedArtElapsedMs = 0L;
            this.consecutivePostFailures += 1;
            if (this.consecutivePostFailures >= POST_FAILURES_BEFORE_REDISCOVERY) {
                this.activeSidecarUrl = "";
                this.consecutivePostFailures = 0;
            }
            throw e5;
        }
    }

    private MediaInfo heartbeatPayload(MediaInfo mediaInfo) {
        String key = artworkKey(mediaInfo);
        long artAgeMs = SystemClock.elapsedRealtime() - this.lastPublishedArtElapsedMs;
        if (!key.isEmpty() && key.equals(this.lastPublishedArtKey)
                && artAgeMs >= 0L && artAgeMs < ART_REFRESH_INTERVAL_MS) {
            return mediaInfo.withoutArt();
        }
        return mediaInfo;
    }

    private static String artworkKey(MediaInfo mediaInfo) {
        if (mediaInfo == null || !mediaInfo.hasArt()) {
            return "";
        }
        return mediaInfo.packageName + "\n" + mediaInfo.title + "\n" + mediaInfo.artHash;
    }

    private void scheduleArtworkPublish(final String sidecarUrl, final MediaInfo basicMedia) {
        if (!this.artworkPublishing.compareAndSet(false, true)) {
            return;
        }
        this.artworkExecutor.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    MediaInfo enrichedMedia = PhoneMediaNotificationListener.this.readMediaInfo(true);
                    if (enrichedMedia.hasArt() && sameMediaItem(basicMedia, enrichedMedia)) {
                        String key = artworkKey(enrichedMedia);
                        long artAgeMs = SystemClock.elapsedRealtime()
                                - PhoneMediaNotificationListener.this.lastPublishedArtElapsedMs;
                        if (!key.isEmpty() && key.equals(PhoneMediaNotificationListener.this.lastPublishedArtKey)
                                && artAgeMs >= 0L && artAgeMs < ART_REFRESH_INTERVAL_MS) {
                            return;
                        }
                        PhoneMediaNotificationListener.this.cachedArtworkMedia = enrichedMedia;
                        PhoneMediaNotificationListener.this.postJson(
                                sidecarUrl + "/phone/media", enrichedMedia.toJson().toString());
                        PhoneMediaNotificationListener.this.consecutivePostFailures = 0;
                        PhoneMediaNotificationListener.this.lastPublishedArtKey = key;
                        PhoneMediaNotificationListener.this.lastPublishedArtElapsedMs = SystemClock.elapsedRealtime();
                        Log.d(TAG, "published enriched artwork bytes=" + enrichedMedia.artByteCount
                                + " source=" + enrichedMedia.artSource);
                    }
                } catch (Exception e) {
                    PhoneMediaNotificationListener.this.lastPublishedArtKey = "";
                    PhoneMediaNotificationListener.this.lastPublishedArtElapsedMs = 0L;
                    Log.w(TAG, "artwork publish failed", e);
                } finally {
                    PhoneMediaNotificationListener.this.artworkPublishing.set(false);
                }
            }
        });
    }

    private MediaInfo readMediaInfo(boolean includeExtendedArtwork) {
        MediaInfo session = readFromActiveSessions(includeExtendedArtwork);
        MediaInfo notification = readBestNotification(includeExtendedArtwork);
        if (session.hasSessionData() && !session.hasArt() && notification.hasArt() && mediaMatches(session, notification)) {
            session.copyArtFrom(notification);
        }
        return notification.score() > session.score() ? notification : session;
    }

    private MediaInfo readBestNotification(boolean includeExtendedArtwork) {
        StatusBarNotification[] notifications = activeNotifications();
        MediaInfo best = new MediaInfo();
        if (notifications == null) {
            return best;
        }
        for (StatusBarNotification notification : notifications) {
            if (notification == null || getPackageName().equals(notification.getPackageName())) {
                continue;
            }
            try {
                MediaInfo candidate = readFromNotification(notification, includeExtendedArtwork);
                if (candidate.score() > best.score()) {
                    best = candidate;
                }
            } catch (Exception e) {
                Log.d(TAG, "notification media read failed", e);
            }
        }
        return best;
    }

    private static boolean mediaMatches(MediaInfo first, MediaInfo second) {
        if (!first.packageName.isEmpty() && first.packageName.equals(second.packageName)) {
            return true;
        }
        String firstTitle = first.title.trim();
        String secondTitle = second.title.trim();
        return !firstTitle.isEmpty() && firstTitle.equalsIgnoreCase(secondTitle);
    }

    private static boolean sameMediaItem(MediaInfo first, MediaInfo second) {
        String firstTitle = first.title.trim();
        String secondTitle = second.title.trim();
        if (!firstTitle.isEmpty() && !secondTitle.isEmpty()) {
            return firstTitle.equalsIgnoreCase(secondTitle);
        }
        return !first.packageName.isEmpty() && first.packageName.equals(second.packageName);
    }

    private MediaInfo readFromActiveSessions(boolean includeExtendedArtwork) {
        try {
            MediaSessionManager mediaSessionManager = (MediaSessionManager) getSystemService("media_session");
            if (mediaSessionManager == null) {
                return new MediaInfo();
            }
            MediaInfo best = new MediaInfo();
            for (MediaController mediaController : mediaSessionManager.getActiveSessions(new ComponentName(this, (Class<?>) PhoneMediaNotificationListener.class))) {
                if (mediaController != null && !getPackageName().equals(mediaController.getPackageName())) {
                    MediaInfo candidate = new MediaInfo();
                    candidate.packageName = safeString(mediaController.getPackageName());
                    readFromController(candidate, mediaController, includeExtendedArtwork);
                    if (includeExtendedArtwork && candidate.artBitmap == null) {
                        candidate.artBitmap = notificationArtForPackage(candidate.packageName, true);
                        if (candidate.artBitmap != null) {
                            candidate.artSource = "notification.package";
                        }
                    }
                    candidate.encodeArt();
                    if (candidate.score() > best.score()) {
                        best = candidate;
                    }
                }
            }
            return best;
        } catch (Exception e5) {
            Log.w(TAG, "active session read failed", e5);
            return new MediaInfo();
        }
    }

    private MediaInfo readFromNotification(StatusBarNotification statusBarNotification, boolean includeExtendedArtwork) {
        MediaInfo mediaInfo = new MediaInfo();
        mediaInfo.packageName = safeString(statusBarNotification.getPackageName());
        Notification notification = statusBarNotification.getNotification();
        if (notification == null) {
            return mediaInfo;
        }
        Bundle bundle = notification.extras;
        Parcelable parcelable = bundle == null ? null : bundle.getParcelable("android.mediaSession");
        boolean z5 = parcelable instanceof MediaSession.Token;
        if (!z5 && !"transport".equals(notification.category)) {
            return new MediaInfo();
        }
        if (z5) {
            readFromController(mediaInfo, new MediaController(this, (MediaSession.Token) parcelable), includeExtendedArtwork);
        }
        if (bundle != null) {
            if (mediaInfo.title.isEmpty()) {
                mediaInfo.title = safeCharSequence(bundle.getCharSequence("android.title"));
            }
            if (mediaInfo.artist.isEmpty()) {
                mediaInfo.artist = safeCharSequence(bundle.getCharSequence("android.text"));
            }
        }
        if (mediaInfo.artBitmap == null) {
            mediaInfo.artBitmap = bitmapFromNotification(notification, includeExtendedArtwork);
            if (mediaInfo.artBitmap != null) {
                mediaInfo.artSource = "notification.extras";
            }
        }
        mediaInfo.encodeArt();
        return mediaInfo;
    }

    private void readFromController(MediaInfo mediaInfo, MediaController mediaController, boolean includeExtendedArtwork) {
        MediaMetadata metadata = mediaController.getMetadata();
        if (metadata != null) {
            mediaInfo.title = firstNonEmpty(safeCharSequence(metadata.getText("android.media.metadata.DISPLAY_TITLE")), safeCharSequence(metadata.getText("android.media.metadata.TITLE")), mediaInfo.title);
            mediaInfo.artist = firstNonEmpty(safeCharSequence(metadata.getText("android.media.metadata.ARTIST")), safeCharSequence(metadata.getText("android.media.metadata.DISPLAY_SUBTITLE")), mediaInfo.artist);
            long j5 = metadata.getLong("android.media.metadata.DURATION");
            if (j5 > 0) {
                mediaInfo.durationMs = Long.valueOf(j5);
            }
            mediaInfo.artBitmap = firstBitmap(metadata.getBitmap("android.media.metadata.ALBUM_ART"), metadata.getBitmap("android.media.metadata.ART"), metadata.getBitmap("android.media.metadata.DISPLAY_ICON"));
            if (mediaInfo.artBitmap != null) {
                mediaInfo.artSource = "metadata.bitmap";
            }
            if (includeExtendedArtwork && mediaInfo.artBitmap == null) {
                mediaInfo.artBitmap = bitmapFromUri(firstNonEmpty(metadata.getString("android.media.metadata.ALBUM_ART_URI"), metadata.getString("android.media.metadata.ART_URI"), metadata.getString("android.media.metadata.DISPLAY_ICON_URI")));
                if (mediaInfo.artBitmap != null) {
                    mediaInfo.artSource = "metadata.uri";
                }
            }
            MediaDescription description = metadata.getDescription();
            if (description != null) {
                mediaInfo.title = firstNonEmpty(mediaInfo.title, safeCharSequence(description.getTitle()), "");
                mediaInfo.artist = firstNonEmpty(mediaInfo.artist, safeCharSequence(description.getSubtitle()), "");
                if (mediaInfo.artBitmap == null) {
                    mediaInfo.artBitmap = description.getIconBitmap();
                    if (mediaInfo.artBitmap != null) {
                        mediaInfo.artSource = "description.bitmap";
                    }
                }
                if (includeExtendedArtwork && mediaInfo.artBitmap == null && description.getIconUri() != null) {
                    mediaInfo.artBitmap = bitmapFromUri(description.getIconUri().toString());
                    if (mediaInfo.artBitmap != null) {
                        mediaInfo.artSource = "description.uri";
                    }
                }
                if (includeExtendedArtwork && mediaInfo.artBitmap == null) {
                    mediaInfo.artBitmap = bitmapFromBundle(description.getExtras(), 0);
                    if (mediaInfo.artBitmap != null) {
                        mediaInfo.artSource = "description.extras";
                    }
                }
            }
            if (includeExtendedArtwork && mediaInfo.artBitmap == null) {
                mediaInfo.artBitmap = bitmapFromMetadataKeys(metadata);
                if (mediaInfo.artBitmap != null) {
                    mediaInfo.artSource = "metadata.custom";
                }
            }
        }
        if (includeExtendedArtwork && mediaInfo.artBitmap == null) {
            try {
                mediaInfo.artBitmap = bitmapFromBundle(mediaController.getExtras(), 0);
                if (mediaInfo.artBitmap != null) {
                    mediaInfo.artSource = "session.extras";
                }
            } catch (Exception ignored) {
            }
        }
        if (includeExtendedArtwork && mediaInfo.artBitmap == null) {
            mediaInfo.artBitmap = bitmapFromQueue(mediaController);
            if (mediaInfo.artBitmap != null) {
                mediaInfo.artSource = "queue.description";
            }
        }
        PlaybackState playbackState = mediaController.getPlaybackState();
        if (playbackState != null) {
            int state = playbackState.getState();
            mediaInfo.isPlaying = state == PlaybackState.STATE_PLAYING
                    || state == PlaybackState.STATE_FAST_FORWARDING
                    || state == PlaybackState.STATE_BUFFERING;
            long position = playbackState.getPosition();
            if (position >= 0) {
                if (mediaInfo.isPlaying && playbackState.getLastPositionUpdateTime() > 0) {
                    position += Math.max(0L, SystemClock.elapsedRealtime() - playbackState.getLastPositionUpdateTime());
                }
                mediaInfo.positionMs = Long.valueOf(position);
            }
        }
    }

    private Bitmap bitmapFromQueue(MediaController mediaController) {
        try {
            List<MediaSession.QueueItem> queue = mediaController.getQueue();
            if (queue == null || queue.isEmpty()) {
                return null;
            }
            PlaybackState playbackState = mediaController.getPlaybackState();
            long activeId = playbackState == null
                    ? MediaSession.QueueItem.UNKNOWN_ID : playbackState.getActiveQueueItemId();
            if (activeId != MediaSession.QueueItem.UNKNOWN_ID) {
                for (MediaSession.QueueItem item : queue) {
                    if (item != null && item.getQueueId() == activeId) {
                        Bitmap bitmap = bitmapFromDescription(item.getDescription());
                        if (bitmap != null) {
                            return bitmap;
                        }
                    }
                }
            }
            for (MediaSession.QueueItem item : queue) {
                if (item != null) {
                    Bitmap bitmap = bitmapFromDescription(item.getDescription());
                    if (bitmap != null) {
                        return bitmap;
                    }
                }
            }
        } catch (Exception ignored) {
        }
        return null;
    }

    private Bitmap bitmapFromDescription(MediaDescription description) {
        if (description == null) {
            return null;
        }
        if (description.getIconBitmap() != null) {
            return description.getIconBitmap();
        }
        if (description.getIconUri() != null) {
            Bitmap bitmap = bitmapFromUri(description.getIconUri().toString());
            if (bitmap != null) {
                return bitmap;
            }
        }
        return bitmapFromBundle(description.getExtras(), 0);
    }

    private StatusBarNotification[] activeNotifications() {
        try {
            return getActiveNotifications();
        } catch (Exception e5) {
            return null;
        }
    }

    private Bitmap notificationArtForPackage(String str, boolean includeExtendedArtwork) {
        Notification notification;
        Bitmap bitmapBitmapFromNotification;
        StatusBarNotification[] statusBarNotificationArrActiveNotifications = activeNotifications();
        Bitmap bitmap = null;
        if (statusBarNotificationArrActiveNotifications == null) {
            return null;
        }
        for (StatusBarNotification statusBarNotification : statusBarNotificationArrActiveNotifications) {
            if (statusBarNotification != null && str.equals(statusBarNotification.getPackageName()) && (notification = statusBarNotification.getNotification()) != null && (bitmapBitmapFromNotification = bitmapFromNotification(notification, includeExtendedArtwork)) != null) {
                Bundle bundle = notification.extras;
                if ("transport".equals(notification.category) || (bundle != null && (bundle.getParcelable("android.mediaSession") instanceof MediaSession.Token))) {
                    return bitmapBitmapFromNotification;
                }
                if (bitmap == null) {
                    bitmap = bitmapBitmapFromNotification;
                }
            }
        }
        return bitmap;
    }

    private Bitmap bitmapFromNotification(Notification notification, boolean includeExtendedArtwork) {
        try {
            Bitmap bitmap = bitmapFromIcon(notification.getLargeIcon());
            if (bitmap != null) {
                return bitmap;
            }
            if (notification.largeIcon != null) {
                return notification.largeIcon;
            }
        } catch (Exception ignored) {
        }
        if (!includeExtendedArtwork) {
            return null;
        }
        Bundle bundle = notification.extras;
        if (bundle == null) {
            return null;
        }
        String[] preferredKeys = {
                Notification.EXTRA_LARGE_ICON,
                Notification.EXTRA_LARGE_ICON_BIG,
                Notification.EXTRA_PICTURE,
                Notification.EXTRA_PICTURE_ICON,
                "android.albumArt",
                "android.art",
                "android.mediaMetadata"
        };
        for (String key : preferredKeys) {
            try {
                Bitmap bitmap = bitmapFromObject(bundle.get(key), 0);
                if (bitmap != null) {
                    return bitmap;
                }
            } catch (Exception ignored) {
            }
        }
        return bitmapFromBundle(bundle, 0);
    }

    private Bitmap bitmapFromMetadataKeys(MediaMetadata metadata) {
        if (metadata == null) {
            return null;
        }
        for (String key : metadata.keySet()) {
            try {
                Bitmap bitmap = metadata.getBitmap(key);
                if (bitmap != null) {
                    return bitmap;
                }
            } catch (Exception ignored) {
            }
            if (!looksLikeArtworkKey(key)) {
                continue;
            }
            try {
                Bitmap bitmap = bitmapFromUriValue(metadata.getString(key));
                if (bitmap != null) {
                    return bitmap;
                }
            } catch (Exception ignored) {
            }
        }
        return null;
    }

    private Bitmap bitmapFromBundle(Bundle bundle, int depth) {
        if (bundle == null || depth > 2) {
            return null;
        }
        for (String key : bundle.keySet()) {
            if (!looksLikeArtworkKey(key)) {
                continue;
            }
            try {
                Bitmap bitmap = bitmapFromObject(bundle.get(key), depth + 1);
                if (bitmap != null) {
                    return bitmap;
                }
            } catch (Exception ignored) {
            }
        }
        for (String key : bundle.keySet()) {
            if (looksLikeArtworkKey(key)) {
                continue;
            }
            try {
                Object value = bundle.get(key);
                if (value instanceof Bundle || value instanceof MediaMetadata
                        || value instanceof MediaDescription || value instanceof Object[]) {
                    Bitmap bitmap = bitmapFromObject(value, depth + 1);
                    if (bitmap != null) {
                        return bitmap;
                    }
                }
            } catch (Exception ignored) {
            }
        }
        return null;
    }

    private Bitmap bitmapFromObject(Object value, int depth) {
        if (value == null || depth > 3) {
            return null;
        }
        if (value instanceof Bitmap) {
            return (Bitmap) value;
        }
        if (value instanceof Icon) {
            return bitmapFromIcon((Icon) value);
        }
        if (value instanceof Uri) {
            return bitmapFromUri(value.toString());
        }
        if (value instanceof String) {
            return bitmapFromUriValue((String) value);
        }
        if (value instanceof byte[]) {
            byte[] bytes = (byte[]) value;
            return bytes.length > 0 && bytes.length <= 8 * 1024 * 1024
                    ? BitmapFactory.decodeByteArray(bytes, 0, bytes.length) : null;
        }
        if (value instanceof Bundle) {
            return bitmapFromBundle((Bundle) value, depth + 1);
        }
        if (value instanceof MediaMetadata) {
            return bitmapFromMetadataKeys((MediaMetadata) value);
        }
        if (value instanceof MediaDescription) {
            MediaDescription description = (MediaDescription) value;
            if (description.getIconBitmap() != null) {
                return description.getIconBitmap();
            }
            if (description.getIconUri() != null) {
                Bitmap bitmap = bitmapFromUri(description.getIconUri().toString());
                if (bitmap != null) {
                    return bitmap;
                }
            }
            return bitmapFromBundle(description.getExtras(), depth + 1);
        }
        if (value instanceof Object[]) {
            for (Object item : (Object[]) value) {
                Bitmap bitmap = bitmapFromObject(item, depth + 1);
                if (bitmap != null) {
                    return bitmap;
                }
            }
        }
        return null;
    }

    private Bitmap bitmapFromUriValue(String value) {
        if (value == null) {
            return null;
        }
        String uri = value.trim().toLowerCase(Locale.US);
        if (!uri.startsWith("http://") && !uri.startsWith("https://")
                && !uri.startsWith("content://") && !uri.startsWith("file://")
                && !uri.startsWith("android.resource://")) {
            return null;
        }
        return bitmapFromUri(value);
    }

    private static boolean looksLikeArtworkKey(String key) {
        if (key == null) {
            return false;
        }
        String lower = key.toLowerCase(Locale.US);
        if (lower.contains("smallicon") || lower.contains("small_icon")) {
            return false;
        }
        return lower.contains("albumart") || lower.contains("album_art")
                || lower.contains("artwork") || lower.contains("cover")
                || lower.contains("picture") || lower.contains("thumbnail")
                || lower.contains("largeicon") || lower.contains("large_icon")
                || lower.contains("displayicon") || lower.contains("display_icon")
                || lower.contains("image") || lower.endsWith(".art")
                || lower.endsWith("_art");
    }

    private Bitmap bitmapFromIcon(Icon icon) {
        if (icon == null) {
            return null;
        }
        try {
            Drawable drawableLoadDrawable = icon.loadDrawable(this);
            if (drawableLoadDrawable == null) {
                return null;
            }
            if (drawableLoadDrawable instanceof BitmapDrawable) {
                return ((BitmapDrawable) drawableLoadDrawable).getBitmap();
            }
            int iMax = Math.max(1, drawableLoadDrawable.getIntrinsicWidth());
            int iMax2 = Math.max(1, drawableLoadDrawable.getIntrinsicHeight());
            Bitmap bitmapCreateBitmap = Bitmap.createBitmap(iMax, iMax2, Bitmap.Config.ARGB_8888);
            Canvas canvas = new Canvas(bitmapCreateBitmap);
            drawableLoadDrawable.setBounds(0, 0, iMax, iMax2);
            drawableLoadDrawable.draw(canvas);
            return bitmapCreateBitmap;
        } catch (Exception e5) {
            return null;
        }
    }

    private Bitmap bitmapFromUri(String value) {
        if (value == null || value.trim().isEmpty()) {
            return null;
        }
        String uriValue = value.trim();
        if (uriValue.equals(this.cachedArtUri) && this.cachedArtBitmap != null) {
            return this.cachedArtBitmap;
        }
        InputStream input = null;
        HttpURLConnection connection = null;
        try {
            Uri uri = Uri.parse(uriValue);
            String scheme = uri.getScheme();
            if ("http".equalsIgnoreCase(scheme) || "https".equalsIgnoreCase(scheme)) {
                connection = (HttpURLConnection) new URL(uriValue).openConnection();
                connection.setConnectTimeout(1800);
                connection.setReadTimeout(2500);
                connection.setInstanceFollowRedirects(true);
                connection.setRequestProperty("Accept", "image/avif,image/webp,image/*,*/*;q=0.8");
                connection.setRequestProperty("User-Agent", "Mozilla/5.0 (Android) CarrotLink/2.0106.4");
                long contentLength = connection.getContentLengthLong();
                if (contentLength > 8L * 1024L * 1024L) {
                    return null;
                }
                input = connection.getInputStream();
            } else {
                input = getContentResolver().openInputStream(uri);
            }
            Bitmap bitmap = input == null ? null : BitmapFactory.decodeStream(input);
            if (bitmap != null) {
                this.cachedArtUri = uriValue;
                this.cachedArtBitmap = bitmap;
            }
            return bitmap;
        } catch (Exception exception) {
            Log.d(TAG, "album art URI read failed: " + uriValue, exception);
            return null;
        } finally {
            if (input != null) {
                try {
                    input.close();
                } catch (Exception ignored) {
                }
            }
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private String findSidecarUrl() {
        SharedPreferences sharedPreferences = getSharedPreferences(PREFS, 0);
        String configuredHost = preferredHost;
        if (configuredHost.isEmpty()) {
            configuredHost = normalizeHost(sharedPreferences.getString(PREF_HOST, ""));
        }
        if (!this.activeSidecarUrl.isEmpty()
                && (configuredHost.isEmpty() || configuredHost.equalsIgnoreCase(hostFromUrl(this.activeSidecarUrl)))) {
            return this.activeSidecarUrl;
        }
        this.activeSidecarUrl = "";
        String string = sharedPreferences.getString(PREF_URL, "");
        if (isSidecar(string)) {
            return rememberSidecar(sharedPreferences, string);
        }
        for (String str : candidateUrls()) {
            if (isSidecar(str)) {
                return rememberSidecar(sharedPreferences, str);
            }
        }
        return "";
    }

    private String rememberSidecar(SharedPreferences sharedPreferences, String str) {
        this.activeSidecarUrl = str;
        String connectedHost = hostFromUrl(str);
        SharedPreferences.Editor editor = sharedPreferences.edit().putString(PREF_URL, str);
        if (!connectedHost.isEmpty()) {
            preferredHost = connectedHost;
            editor.putString(PREF_HOST, connectedHost);
        }
        editor.apply();
        Log.i(TAG, "sidecar connected: " + str);
        return str;
    }

    private List<String> candidateUrls() {
        LinkedHashSet linkedHashSet = new LinkedHashSet();
        addHostUrls(linkedHashSet, preferredHost);
        addHostUrls(linkedHashSet, getSharedPreferences(PREFS, 0).getString(PREF_HOST, ""));
        addHostUrls(linkedHashSet, "127.0.0.1");
        addHostsFromAppData(linkedHashSet);
        String strWifiGatewayAddress = wifiGatewayAddress();
        if (!strWifiGatewayAddress.isEmpty()) {
            addNetworkCandidates(linkedHashSet, strWifiGatewayAddress);
        }
        try {
            Enumeration<NetworkInterface> networkInterfaces = NetworkInterface.getNetworkInterfaces();
            while (networkInterfaces != null) {
                if (!networkInterfaces.hasMoreElements()) {
                    break;
                }
                Enumeration<InetAddress> inetAddresses = networkInterfaces.nextElement().getInetAddresses();
                while (inetAddresses.hasMoreElements()) {
                    InetAddress inetAddressNextElement = inetAddresses.nextElement();
                    if ((inetAddressNextElement instanceof Inet4Address) && !inetAddressNextElement.isLoopbackAddress()) {
                        addNetworkCandidates(linkedHashSet, inetAddressNextElement.getHostAddress());
                    }
                }
            }
        } catch (Exception e5) {
        }
        addHostUrls(linkedHashSet, "192.168.43.1");
        addHostUrls(linkedHashSet, "192.168.1.1");
        addHostUrls(linkedHashSet, "10.0.0.1");
        addHostUrls(linkedHashSet, "comma.local");
        return new ArrayList(linkedHashSet);
    }

    private void addHostsFromAppData(Set<String> set) {
        scanDataDirectory(new File(getApplicationInfo().dataDir, "shared_prefs"), set, 0);
        scanDataDirectory(new File(getApplicationInfo().dataDir, "datastore"), set, 0);
    }

    private void scanDataDirectory(File file, Set<String> set, int i) {
        if (file == null || !file.exists() || i > 3) {
            return;
        }
        if (file.isDirectory()) {
            File[] fileArrListFiles = file.listFiles();
            if (fileArrListFiles != null) {
                for (File file2 : fileArrListFiles) {
                    scanDataDirectory(file2, set, i + 1);
                }
                return;
            }
            return;
        }
        if (file.length() <= 0 || file.length() > 1048576) {
            return;
        }
        try {
            FileInputStream fileInputStream = new FileInputStream(file);
            try {
                byte[] bArr = new byte[(int) file.length()];
                int i5 = fileInputStream.read(bArr);
                if (i5 > 0) {
                    addUrlsFromText(set, new String(bArr, 0, i5, "UTF-8"));
                }
                fileInputStream.close();
            } finally {
            }
        } catch (Exception e5) {
        }
    }

    private void addUrlsFromText(Set<String> set, String str) {
        Matcher matcher = IPV4.matcher(str);
        while (matcher.find()) {
            String strGroup = matcher.group(1);
            String strGroup2 = matcher.group(2);
            if (validIpv4(strGroup)) {
                if (strGroup2 != null) {
                    set.add("http://" + strGroup + ":" + strGroup2);
                }
                addHostUrls(set, strGroup);
            }
        }
    }

    private boolean validIpv4(String str) {
        try {
            String[] strArrSplit = str.split("\\.");
            if (strArrSplit.length != 4) {
                return false;
            }
            for (String str2 : strArrSplit) {
                int i = Integer.parseInt(str2);
                if (i < 0 || i > 255) {
                    return false;
                }
            }
            return true;
        } catch (Exception e5) {
            return false;
        }
    }

    private void addNetworkCandidates(Set<String> set, String str) {
        addHostUrls(set, str);
        int iLastIndexOf = str.lastIndexOf(46);
        if (iLastIndexOf <= 0) {
            return;
        }
        String strSubstring = str.substring(0, iLastIndexOf + 1);
        addHostUrls(set, strSubstring + "1");
        addHostUrls(set, strSubstring + "2");
        addHostUrls(set, strSubstring + "10");
        addHostUrls(set, strSubstring + "100");
    }

    private void addHostUrls(Set<String> set, String str) {
        if (str == null || str.trim().isEmpty()) {
            return;
        }
        for (String str2 : PORTS) {
            set.add("http://" + str.trim() + ":" + str2);
        }
    }

    private String wifiGatewayAddress() {
        try {
            WifiManager wifiManager = (WifiManager) getApplicationContext().getSystemService("wifi");
            DhcpInfo dhcpInfo = wifiManager == null ? null : wifiManager.getDhcpInfo();
            if (dhcpInfo != null && dhcpInfo.gateway != 0) {
                int i = dhcpInfo.gateway;
                return String.format(Locale.US, "%d.%d.%d.%d", Integer.valueOf(i & 255), Integer.valueOf((i >> 8) & 255), Integer.valueOf((i >> 16) & 255), Integer.valueOf((i >> 24) & 255));
            }
            return "";
        } catch (Exception e5) {
            return "";
        }
    }

    private boolean isSidecar(String url) {
        if (url == null || url.isEmpty()) {
            return false;
        }
        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection) new URL(url + "/health").openConnection();
            connection.setConnectTimeout(HEALTH_TIMEOUT_MS);
            connection.setReadTimeout(HEALTH_TIMEOUT_MS);
            connection.setUseCaches(false);
            connection.setRequestMethod("GET");
            int status = connection.getResponseCode();
            return status >= 200 && status < 300;
        } catch (Exception ignored) {
            return false;
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private void postJson(String url, String json) throws Exception {
        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection) new URL(url).openConnection();
            connection.setConnectTimeout(POST_CONNECT_TIMEOUT_MS);
            connection.setReadTimeout(POST_READ_TIMEOUT_MS);
            connection.setUseCaches(false);
            connection.setRequestMethod("POST");
            connection.setDoOutput(true);
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            byte[] bytes = json.getBytes("UTF-8");
            connection.setFixedLengthStreamingMode(bytes.length);
            try (OutputStream output = connection.getOutputStream()) {
                output.write(bytes);
            }
            int status = connection.getResponseCode();
            InputStream response = status >= 400 ? connection.getErrorStream() : connection.getInputStream();
            if (response != null) {
                response.close();
            }
            if (status < 200 || status >= 300) {
                throw new IllegalStateException("HTTP " + status);
            }
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private static String safeCharSequence(CharSequence charSequence) {
        return charSequence == null ? "" : safeString(charSequence.toString());
    }

    private static String safeString(String str) {
        if (str == null) {
            return "";
        }
        String strTrim = str.trim();
        return strTrim.codePointCount(0, strTrim.length()) <= TEXT_MAX_CODEPOINTS ? strTrim : strTrim.substring(0, strTrim.offsetByCodePoints(0, TEXT_MAX_CODEPOINTS));
    }

    private static String firstNonEmpty(String str, String str2, String str3) {
        return (str == null || str.isEmpty()) ? (str2 == null || str2.isEmpty()) ? str3 == null ? "" : str3 : str2 : str;
    }

    private static Bitmap firstBitmap(Bitmap bitmap, Bitmap bitmap2, Bitmap bitmap3) {
        return bitmap != null ? bitmap : bitmap2 != null ? bitmap2 : bitmap3;
    }

    /* JADX INFO: Access modifiers changed from: private */
    public static String sha256Hex(byte[] bArr) {
        try {
            byte[] bArrDigest = MessageDigest.getInstance("SHA-256").digest(bArr);
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < Math.min(16, bArrDigest.length); i++) {
                sb.append(String.format(Locale.US, "%02x", Integer.valueOf(bArrDigest[i] & 255)));
            }
            return sb.toString();
        } catch (Exception e5) {
            return "";
        }
    }

    private static final class MediaInfo {
        String artBase64;
        Bitmap artBitmap;
        int artByteCount;
        String artHash;
        String artMime;
        String artSource;
        String artist;
        Long durationMs;
        boolean isPlaying;
        String packageName;
        Long positionMs;
        String title;

        private MediaInfo() {
            this.title = "";
            this.artist = "";
            this.packageName = "";
            this.artBase64 = "";
            this.artMime = "";
            this.artHash = "";
            this.artSource = "";
        }

        boolean hasSessionData() {
            return (this.title.isEmpty() && this.artist.isEmpty() && this.artBitmap == null) ? false : true;
        }

        boolean hasAnyData() {
            return hasSessionData() || !this.packageName.isEmpty();
        }

        boolean hasDisplayData() {
            return !this.title.isEmpty() || !this.artist.isEmpty() || hasArt();
        }

        boolean hasArt() {
            return !this.artBase64.isEmpty();
        }

        int score() {
            if (!hasAnyData()) {
                return -1;
            }
            int score = this.isPlaying ? 1000 : 0;
            if (hasArt()) {
                score += 300;
            }
            if (!this.title.isEmpty()) {
                score += 80;
            }
            if (!this.artist.isEmpty()) {
                score += 30;
            }
            if (this.durationMs != null) {
                score += 10;
            }
            return score;
        }

        void copyArtFrom(MediaInfo other) {
            this.artBitmap = other.artBitmap;
            this.artBase64 = other.artBase64;
            this.artMime = other.artMime;
            this.artHash = other.artHash;
            this.artByteCount = other.artByteCount;
            this.artSource = other.artSource;
        }

        MediaInfo withoutArt() {
            MediaInfo copy = new MediaInfo();
            copy.title = this.title;
            copy.artist = this.artist;
            copy.packageName = this.packageName;
            copy.isPlaying = this.isPlaying;
            copy.durationMs = this.durationMs;
            copy.positionMs = this.positionMs;
            return copy;
        }

        void encodeArt() {
            Bitmap bitmapCreateScaledBitmap = this.artBitmap;
            if (bitmapCreateScaledBitmap == null) {
                return;
            }
            try {
                Bitmap softwareBitmap = bitmapCreateScaledBitmap.copy(Bitmap.Config.ARGB_8888, false);
                if (softwareBitmap != null) {
                    bitmapCreateScaledBitmap = softwareBitmap;
                }
                int width = bitmapCreateScaledBitmap.getWidth();
                int height = bitmapCreateScaledBitmap.getHeight();
                if (width > 0 && height > 0) {
                    float fMin = Math.min(1.0f, 256.0f / Math.max(width, height));
                    if (fMin < 1.0f) {
                        bitmapCreateScaledBitmap = Bitmap.createScaledBitmap(bitmapCreateScaledBitmap, Math.max(1, Math.round(width * fMin)), Math.max(1, Math.round(height * fMin)), true);
                    }
                    ByteArrayOutputStream byteArrayOutputStream = new ByteArrayOutputStream();
                    if (bitmapCreateScaledBitmap.compress(Bitmap.CompressFormat.JPEG, PhoneMediaNotificationListener.ART_QUALITY, byteArrayOutputStream)) {
                        byte[] byteArray = byteArrayOutputStream.toByteArray();
                        this.artByteCount = byteArray.length;
                        this.artBase64 = Base64.encodeToString(byteArray, 2);
                        this.artMime = "image/jpeg";
                        this.artHash = PhoneMediaNotificationListener.sha256Hex(byteArray);
                    }
                }
            } catch (Exception e5) {
                this.artBase64 = "";
                this.artMime = "";
                this.artHash = "";
                this.artByteCount = 0;
            }
        }

        JSONObject toJson() throws Exception {
            JSONObject jSONObject = new JSONObject();
            jSONObject.put("title", this.title);
            jSONObject.put("artist", this.artist);
            jSONObject.put("package", this.packageName);
            jSONObject.put("isPlaying", this.isPlaying);
            Long l5 = this.durationMs;
            if (l5 != null) {
                jSONObject.put("durationMs", l5);
            }
            Long l6 = this.positionMs;
            if (l6 != null) {
                jSONObject.put("positionMs", l6);
            }
            jSONObject.put("artBase64", this.artBase64);
            jSONObject.put("artMime", this.artMime);
            jSONObject.put("artHash", this.artHash);
            jSONObject.put("artSource", this.artSource);
            jSONObject.put("updatedAtMs", System.currentTimeMillis());
            return jSONObject;
        }
    }
}
