package com.limlink.app.preview

import org.junit.Assert.*
import org.junit.Test

class PreviewAudioPlaybackTest {
    private class NativePlayer {
        var started = false
        var pauses = 0
        fun start() { started = true }
        fun pause() { check(started) { "pause is invalid in Prepared" }; pauses++; started = false }
    }

    @Test fun backgroundBeforeFirstPlayDoesNotPausePreparedPlayer() {
        val native = NativePlayer()
        assertEquals(PreviewAudioState.PREPARED, PreviewAudioPlayback.background(PreviewAudioState.PREPARED, native::pause))
        assertEquals(0, native.pauses)
    }

    @Test fun backgroundPausesAnActuallyStartedPlayerOnlyOnce() {
        val native = NativePlayer()
        val playing = PreviewAudioPlayback.toggle(PreviewAudioState.PREPARED, native::start, native::pause)
        assertEquals(PreviewAudioState.PLAYING, playing)
        val paused = PreviewAudioPlayback.background(playing, native::pause)
        assertEquals(PreviewAudioState.PAUSED, paused)
        assertEquals(paused, PreviewAudioPlayback.background(paused, native::pause))
        assertEquals(1, native.pauses)
    }

    @Test fun errorOrReleasedPlayerNeverReceivesPlaybackActions() {
        val forbidden: () -> Unit = { error("released/error player must not be used") }
        for (state in listOf(PreviewAudioState.ERROR, PreviewAudioState.RELEASED)) {
            assertEquals(state, PreviewAudioPlayback.background(state, forbidden))
            assertEquals(state, PreviewAudioPlayback.toggle(state, forbidden, forbidden))
        }
        assertEquals(PreviewAudioState.ERROR, PreviewAudioPlayback.background(PreviewAudioState.PLAYING) { error("native failure") })
    }
}
