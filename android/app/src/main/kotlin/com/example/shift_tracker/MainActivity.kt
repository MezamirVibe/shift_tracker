package com.example.shift_tracker

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private var checkingUpdate = false
    private var notificationBridge: NotificationBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        notificationBridge = NotificationBridge(this, flutterEngine).also {
            it.acceptIntent(intent, notifyFlutter = false)
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chereda/app_updates")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "appInfo" -> {
                        try {
                            val info = installedPackage()
                            result.success(mapOf(
                                "version" to (info.versionName ?: ""),
                                "build" to versionCode(info),
                                "packageName" to packageName,
                            ))
                        } catch (_: Exception) {
                            result.error("app_info", "Не удалось определить версию приложения.", null)
                        }
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        val sha256 = call.argument<String>("sha256")
                        val expectedBuild = call.argument<Number>("build")?.toLong()
                        if (path.isNullOrBlank() || sha256 == null || expectedBuild == null ||
                            expectedBuild <= 0 || !sha256.matches(Regex("[a-fA-F0-9]{64}"))) {
                            result.error("invalid_update", "Не удалось проверить сведения об обновлении.", null)
                        } else if (checkingUpdate) {
                            result.error("update_busy", "Проверка обновления уже выполняется.", null)
                        } else {
                            checkingUpdate = true
                            // An APK can be large. Hashing and package signature parsing must not
                            // block Flutter's platform thread or the Android permission screen.
                            Thread({
                                try {
                                    val apk = verifyUpdate(path, sha256, expectedBuild)
                                    runOnUiThread {
                                        try {
                                            if (isFinishing || isDestroyed) {
                                                result.error("activity_closed", "Откройте приложение и повторите установку.", null)
                                            } else {
                                                openInstaller(apk, result)
                                            }
                                        } catch (_: ActivityNotFoundException) {
                                            result.error("installer_unavailable", "На устройстве недоступен установщик приложений или экран разрешений.", null)
                                        } catch (_: Exception) {
                                            result.error("install_failed", "Не удалось открыть установку. Проверьте разрешение на установку обновлений.", null)
                                        } finally {
                                            checkingUpdate = false
                                        }
                                    }
                                } catch (error: IllegalArgumentException) {
                                    runOnUiThread {
                                        checkingUpdate = false
                                        result.error("invalid_update", error.message, null)
                                    }
                                } catch (_: Exception) {
                                    runOnUiThread {
                                        checkingUpdate = false
                                        result.error("invalid_update", "Не удалось проверить файл обновления. Скачайте его повторно.", null)
                                    }
                                }
                            }, "chereda-update-check").start()
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        notificationBridge?.acceptIntent(intent, notifyFlutter = true)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        notificationBridge?.onPermissionResult(requestCode)
    }

    override fun onDestroy() {
        notificationBridge?.dispose()
        notificationBridge = null
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    private fun installedPackage(): PackageInfo =
        packageManager.getPackageInfo(packageName, signingFlags())

    @Suppress("DEPRECATION")
    private fun signingFlags(): Int = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        PackageManager.GET_SIGNING_CERTIFICATES
    } else {
        PackageManager.GET_SIGNATURES
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode
        else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun currentSigners(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signing = info.signingInfo ?: return emptySet()
            if (signing.hasMultipleSigners()) signing.apkContentsSigners
            else signing.signingCertificateHistory?.takeLast(1)?.toTypedArray()
        } else {
            info.signatures
        }
        return signatures?.map { it.toCharsString() }?.toSet() ?: emptySet()
    }

    @Suppress("DEPRECATION")
    private fun verifyUpdate(path: String, expectedHash: String, expectedBuild: Long): File {
        require(File(path).isAbsolute) { "Некорректный путь к файлу обновления." }
        val apk = File(path).canonicalFile
        val updateRoot = File(cacheDir, "app-updates").canonicalFile
        require(apk.isFile && apk.path.startsWith(updateRoot.path + File.separator) &&
            apk.extension.equals("apk", ignoreCase = true)) {
            "Файл обновления не найден. Скачайте его повторно."
        }
        val digest = MessageDigest.getInstance("SHA-256")
        apk.inputStream().buffered().use { stream ->
            val buffer = ByteArray(256 * 1024)
            while (true) {
                val read = stream.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        val actualHash = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
        require(actualHash.equals(expectedHash, ignoreCase = true)) {
            "Файл обновления повреждён. Скачайте его повторно."
        }
        val archive = packageManager.getPackageArchiveInfo(apk.path, signingFlags())
        require(archive != null && archive.packageName == packageName) {
            "Этот файл не является обновлением «Череды»."
        }
        val installed = installedPackage()
        val archiveBuild = versionCode(archive)
        require(archiveBuild == expectedBuild && archiveBuild > versionCode(installed)) {
            "Версия файла обновления не подходит для установленного приложения."
        }
        val archiveSigners = currentSigners(archive)
        require(archiveSigners.isNotEmpty() && archiveSigners == currentSigners(installed)) {
            "Подпись обновления отличается от установленного приложения. Установка отменена."
        }
        return apk
    }

    private fun openInstaller(apk: File, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()) {
            startActivity(Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            ))
            // Granting permission alone must not silently start installation. The
            // Flutter UI keeps the verified download and offers an explicit retry.
            result.success("permission_required")
            return
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
        startActivity(Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipData = ClipData.newRawUri("Обновление Череды", uri)
        })
        result.success("installer_opened")
    }
}
