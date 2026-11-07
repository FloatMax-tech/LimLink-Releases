package com.limlink.kit.transfer

import java.util.ArrayDeque
import java.util.Locale

enum class SizeUnit {
    B,
    KB,
    MB,
    GB,
}

data class ScaledBytes(
    val number: String,
    val unit: SizeUnit,
)

data class DemoStep(
    val transferred: Long,
    val total: Long,
    val fileIndex: Int,
    val fileCount: Int,
    val done: Boolean,
)

object TransferMath {
    fun percent(transferred: Long, total: Long): Int {
        if (total <= 0L) return 0
        return ((transferred.coerceIn(0L, total) * 100L) / total).toInt()
    }

    fun fraction(transferred: Long, total: Long): Float {
        if (total <= 0L) return 0f
        return (transferred.coerceIn(0L, total).toDouble() / total.toDouble())
            .toFloat()
            .coerceIn(0f, 1f)
    }

    fun scaleBytes(bytes: Long): ScaledBytes {
        val safe = bytes.coerceAtLeast(0L)
        val (value, unit) = when {
            safe >= 1_000_000_000L -> safe / 1_000_000_000.0 to SizeUnit.GB
            safe >= 1_000_000L -> safe / 1_000_000.0 to SizeUnit.MB
            safe >= 1_000L -> safe / 1_000.0 to SizeUnit.KB
            else -> safe.toDouble() to SizeUnit.B
        }
        val number = if (unit == SizeUnit.B) {
            safe.toString()
        } else {
            String.format(Locale.US, "%.1f", value)
        }
        return ScaledBytes(number, unit)
    }

    fun remainingSeconds(remainingBytes: Long, bytesPerSecond: Long): Long? {
        if (bytesPerSecond <= 0L || remainingBytes <= 0L) return null
        return (remainingBytes + bytesPerSecond - 1L) / bytesPerSecond
    }

    fun advance(transferred: Long, total: Long, fileCount: Int, deltaBytes: Long): DemoStep {
        val next = (transferred + deltaBytes.coerceAtLeast(0L)).coerceAtMost(total.coerceAtLeast(0L))
        val count = fileCount.coerceAtLeast(1)
        val index = if (total <= 0L || next >= total) {
            count
        } else {
            ((next * count) / total).toInt().coerceIn(0, count - 1) + 1
        }
        return DemoStep(
            transferred = next,
            total = total.coerceAtLeast(0L),
            fileIndex = index,
            fileCount = count,
            done = total > 0L && next >= total,
        )
    }

    fun fileFraction(fileNumber: Int, fileCount: Int, overall: Float): Float {
        if (fileCount <= 0 || fileNumber !in 1..fileCount) return 0f
        val start = (fileNumber - 1).toFloat() / fileCount
        val end = fileNumber.toFloat() / fileCount
        val clamped = overall.coerceIn(0f, 1f)
        if (clamped >= end) return 1f
        if (clamped <= start) return 0f
        return (clamped - start) / (end - start)
    }
}

class RateWindow {
    private val samples = ArrayDeque<Pair<Long, Long>>()

    fun clear() {
        samples.clear()
    }

    fun add(timeMs: Long, bytes: Long): Long {
        samples.addLast(timeMs to bytes)
        // Drop samples that have fallen out of the window, but keep the newest
        // sample at or before the window edge so a quiet gap still has a baseline.
        while (samples.size > 1 && timeMs - samples.first().first > WINDOW_MS) {
            val next = samples.elementAt(1)
            if (samples.size > 2 && timeMs - next.first > WINDOW_MS) {
                samples.removeFirst()
            } else {
                break
            }
        }
        val first = samples.first()
        val elapsed = timeMs - first.first
        if (elapsed <= 0L) return 0L
        val delta = bytes - first.second
        if (delta <= 0L) return 0L
        return (delta * 1000L) / elapsed
    }

    companion object {
        const val WINDOW_MS = 3_000L
    }
}
