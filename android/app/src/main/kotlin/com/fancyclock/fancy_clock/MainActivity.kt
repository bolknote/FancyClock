package com.fancyclock.fancy_clock

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Size
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import kotlin.math.max

class MainActivity : FlutterActivity() {
    private lateinit var ambientCameraStreamHandler: AmbientCameraStreamHandler

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ambientCameraStreamHandler = AmbientCameraStreamHandler(this)
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "fancy_clock/ambient_lux"
        ).setStreamHandler(ambientCameraStreamHandler)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        ambientCameraStreamHandler.onRequestPermissionsResult(requestCode, grantResults)
    }
}

private class AmbientCameraStreamHandler(
    private val activity: MainActivity
) : EventChannel.StreamHandler {
    private val cameraManager =
        activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    private var events: EventChannel.EventSink? = null
    private var pendingStartAfterPermission = false
    private var handlerThread: HandlerThread? = null
    private var handler: Handler? = null
    private var imageReader: ImageReader? = null
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        this.events = events
        if (activity.checkSelfPermission(Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            pendingStartAfterPermission = true
            activity.requestPermissions(arrayOf(Manifest.permission.CAMERA), CAMERA_PERMISSION_REQUEST)
            return
        }
        startCamera()
    }

    override fun onCancel(arguments: Any?) {
        pendingStartAfterPermission = false
        events = null
        stopCamera()
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != CAMERA_PERMISSION_REQUEST || !pendingStartAfterPermission) {
            return
        }
        pendingStartAfterPermission = false
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            startCamera()
        } else {
            events?.error("CAMERA_DENIED", "Camera permission denied", null)
        }
    }

    @SuppressLint("MissingPermission")
    private fun startCamera() {
        if (cameraDevice != null) {
            return
        }
        val cameraId = chooseCameraId()
        if (cameraId == null) {
            events?.error("NO_CAMERA", "No usable camera for ambient sampling", null)
            return
        }
        val size = chooseSmallYuvSize(cameraId) ?: Size(320, 240)
        val thread = HandlerThread("AmbientCamera")
        thread.start()
        handlerThread = thread
        val h = Handler(thread.looper)
        handler = h
        val reader = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 2)
        imageReader = reader
        reader.setOnImageAvailableListener({ imageReader ->
            val image = imageReader.acquireLatestImage() ?: return@setOnImageAvailableListener
            try {
                emitSuccess(sampleLuma(image))
            } finally {
                image.close()
            }
        }, h)
        cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) {
                cameraDevice = camera
                createCaptureSession(camera, reader, h)
            }

            override fun onDisconnected(camera: CameraDevice) {
                camera.close()
                if (cameraDevice == camera) {
                    cameraDevice = null
                }
            }

            override fun onError(camera: CameraDevice, error: Int) {
                camera.close()
                if (cameraDevice == camera) {
                    cameraDevice = null
                }
                emitError("CAMERA_ERROR", "Camera error $error")
            }
        }, h)
    }

    private fun createCaptureSession(
        camera: CameraDevice,
        reader: ImageReader,
        h: Handler
    ) {
        camera.createCaptureSession(
            listOf(reader.surface),
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    captureSession = session
                    val request = camera
                        .createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                        .apply {
                            addTarget(reader.surface)
                            set(
                                CaptureRequest.CONTROL_AE_MODE,
                                CaptureRequest.CONTROL_AE_MODE_ON
                            )
                        }
                        .build()
                    session.setRepeatingRequest(request, null, h)
                }

                override fun onConfigureFailed(session: CameraCaptureSession) {
                    emitError("CAMERA_SESSION_FAILED", "Camera session failed")
                }
            },
            h
        )
    }

    private fun stopCamera() {
        try {
            captureSession?.stopRepeating()
        } catch (_: Exception) {
        }
        try {
            captureSession?.close()
        } catch (_: Exception) {
        }
        captureSession = null
        try {
            cameraDevice?.close()
        } catch (_: Exception) {
        }
        cameraDevice = null
        try {
            imageReader?.close()
        } catch (_: Exception) {
        }
        imageReader = null
        handler = null
        handlerThread?.quitSafely()
        handlerThread = null
    }

    private fun chooseCameraId(): String? {
        return cameraManager.cameraIdList.firstOrNull { id ->
            val characteristics = cameraManager.getCameraCharacteristics(id)
            characteristics.get(CameraCharacteristics.LENS_FACING) ==
                CameraCharacteristics.LENS_FACING_BACK &&
                chooseSmallYuvSize(id) != null
        } ?: cameraManager.cameraIdList.firstOrNull { id -> chooseSmallYuvSize(id) != null }
    }

    private fun chooseSmallYuvSize(cameraId: String): Size? {
        val characteristics = cameraManager.getCameraCharacteristics(cameraId)
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: return null
        return map.getOutputSizes(ImageFormat.YUV_420_888)
            ?.filter { it.width <= 640 && it.height <= 480 }
            ?.minByOrNull { it.width * it.height }
            ?: map.getOutputSizes(ImageFormat.YUV_420_888)?.minByOrNull { it.width * it.height }
    }

    private fun sampleLuma(image: Image): Double {
        val buffer = image.planes.firstOrNull()?.buffer ?: return 0.5
        val duplicate = buffer.duplicate()
        val length = duplicate.remaining()
        if (length <= 0) {
            return 0.5
        }
        val step = max(1, length / 4096)
        var sum = 0L
        var count = 0
        var index = 0
        while (index < length) {
            sum += duplicate.get(index).toInt() and 0xff
            count++
            index += step
        }
        return if (count == 0) 0.5 else (sum.toDouble() / count) / 255.0
    }

    private fun emitSuccess(value: Double) {
        activity.runOnUiThread {
            events?.success(value)
        }
    }

    private fun emitError(code: String, message: String) {
        activity.runOnUiThread {
            events?.error(code, message, null)
        }
    }

    companion object {
        private const val CAMERA_PERMISSION_REQUEST = 9101
    }
}
