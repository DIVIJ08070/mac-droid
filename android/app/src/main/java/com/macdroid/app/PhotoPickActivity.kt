package com.macdroid.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts

/**
 * Transparent, no-UI activity: opens the system photo picker so the user chooses
 * exactly which gallery photos to send to the Mac, then finishes. Launched when
 * the Mac requests a photo pull.
 */
class PhotoPickActivity : ComponentActivity() {

    private val picker = registerForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(20)
    ) { uris ->
        if (uris.isNotEmpty()) ConnectionManager.sendPickedPhotos(uris)
        finish()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        picker.launch(
            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)
        )
    }
}
