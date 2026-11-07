package com.limlink.app.transfer

import android.content.Context
import com.limlink.app.R
import com.limlink.kit.transfer.SizeUnit
import com.limlink.kit.transfer.TransferMath

fun rateLabel(context: Context, bytesPerSecond: Long): String {
    if (bytesPerSecond <= 0L) return context.getString(R.string.rate_unknown)
    val scaled = TransferMath.scaleBytes(bytesPerSecond)
    val unit = context.getString(
        when (scaled.unit) {
            SizeUnit.B -> R.string.unit_b_per_s
            SizeUnit.KB -> R.string.unit_kb_per_s
            SizeUnit.MB -> R.string.unit_mb_per_s
            SizeUnit.GB -> R.string.unit_gb_per_s
        },
    )
    return context.getString(R.string.rate_value, scaled.number, unit)
}
