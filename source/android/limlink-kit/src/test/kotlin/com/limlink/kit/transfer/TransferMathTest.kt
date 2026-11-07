package com.limlink.kit.transfer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TransferMathTest {
    @Test
    fun percentStaysInsideZeroToOneHundred() {
        assertEquals(0, TransferMath.percent(0, 80))
        assertEquals(62, TransferMath.percent(62, 100))
        assertEquals(100, TransferMath.percent(500, 100))
        assertEquals(0, TransferMath.percent(10, 0))
    }

    @Test
    fun scaleUsesOneDecimalAndThousands() {
        assertEquals(ScaledBytes("12.4", SizeUnit.MB), TransferMath.scaleBytes(12_400_000))
        assertEquals(ScaledBytes("1.0", SizeUnit.KB), TransferMath.scaleBytes(1_000))
        assertEquals(ScaledBytes("8", SizeUnit.B), TransferMath.scaleBytes(8))
    }

    @Test
    fun advanceNeverPassesTheTotal() {
        val step = TransferMath.advance(
            transferred = 70,
            total = 80,
            fileCount = 8,
            deltaBytes = 50,
        )
        assertEquals(80, step.transferred)
        assertTrue(step.done)
        assertEquals(8, step.fileIndex)
    }

    @Test
    fun fileSliceFollowsTheOverallFraction() {
        assertEquals(1f, TransferMath.fileFraction(1, 4, 0.25f))
        assertEquals(0.5f, TransferMath.fileFraction(2, 4, 0.375f), 0.001f)
        assertEquals(0f, TransferMath.fileFraction(4, 4, 0.5f))
    }

    @Test
    fun rateWindowAveragesTheLastThreeSeconds() {
        val window = RateWindow()
        assertEquals(0L, window.add(0L, 0L))
        assertEquals(1_000L, window.add(1_000L, 1_000L))
        assertEquals(1_000L, window.add(5_000L, 5_000L))
    }

    @Test
    fun remainingTimeNeedsAPositiveRate() {
        assertNull(TransferMath.remainingSeconds(1_000, 0))
        assertEquals(2L, TransferMath.remainingSeconds(1_001, 1_000))
    }
}
