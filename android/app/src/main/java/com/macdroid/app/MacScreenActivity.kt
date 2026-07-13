package com.macdroid.app

import android.os.Bundle
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.activity.ComponentActivity

/**
 * Full-screen viewer for the Mac's mirrored screen. Provides a Surface to
 * ConnectionManager, which drives the H.264 decoder onto it.
 */
class MacScreenActivity : ComponentActivity() {

    private lateinit var surfaceView: SurfaceView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        surfaceView = SurfaceView(this)
        val container = FrameLayout(this).apply {
            setBackgroundColor(0xFF000000.toInt())
            addView(
                surfaceView,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT
                ).apply { gravity = android.view.Gravity.CENTER }
            )
        }
        setContentView(container)

        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                ConnectionManager.attachMacScreenSurface(holder.surface)
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                ConnectionManager.detachMacScreenSurface()
            }
        })
    }

    override fun onDestroy() {
        super.onDestroy()
        // Leaving the viewer stops the Mac stream.
        ConnectionManager.stopMacScreen()
    }
}
