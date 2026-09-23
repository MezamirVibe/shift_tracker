package com.example.shift_tracker

import androidx.core.content.FileProvider

/** Dedicated provider: never exposes exports, preferences or other app files. */
class UpdateFileProvider : FileProvider()
