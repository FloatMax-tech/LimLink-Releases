package com.limlink.app.preview

enum class PreviewAudioState { PREPARING, PREPARED, PLAYING, PAUSED, COMPLETED, ERROR, RELEASED }

/** Native pause is valid only after playback starts; Prepared is ready but has never played. */
object PreviewAudioPlayback {
    fun background(state: PreviewAudioState, pause: () -> Unit): PreviewAudioState =
        if (state == PreviewAudioState.PLAYING) attempt(PreviewAudioState.PAUSED, pause) else state

    fun toggle(state: PreviewAudioState, start: () -> Unit, pause: () -> Unit): PreviewAudioState = when (state) {
        PreviewAudioState.PLAYING -> attempt(PreviewAudioState.PAUSED, pause)
        PreviewAudioState.PREPARED, PreviewAudioState.PAUSED, PreviewAudioState.COMPLETED -> attempt(PreviewAudioState.PLAYING, start)
        else -> state
    }
    private fun attempt(next: PreviewAudioState, action: () -> Unit): PreviewAudioState =
        try { action(); next } catch (_: Exception) { PreviewAudioState.ERROR }
}
