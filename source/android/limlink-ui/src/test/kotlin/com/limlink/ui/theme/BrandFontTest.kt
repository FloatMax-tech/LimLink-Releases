package com.limlink.ui.theme

import org.junit.Assert.assertEquals
import org.junit.Test

class BrandFontTest {
    private val all = BrandTextRole.entries.toSet()

    @Test
    fun missingFontFallsBackToTheSystemFont() {
        assertEquals(
            FontSource.SYSTEM,
            resolveBrandFont(
                enabled = true,
                fontProvided = false,
                role = BrandTextRole.BRAND_TITLE,
                appliesTo = all,
            ),
        )
    }

    @Test
    fun disabledSettingFallsBack() {
        assertEquals(
            FontSource.SYSTEM,
            resolveBrandFont(
                enabled = false,
                fontProvided = true,
                role = BrandTextRole.LARGE_TITLE,
                appliesTo = all,
            ),
        )
    }

    @Test
    fun roleOutsideTheSetFallsBack() {
        assertEquals(
            FontSource.SYSTEM,
            resolveBrandFont(
                enabled = true,
                fontProvided = true,
                role = BrandTextRole.INVITE_DIGITS,
                appliesTo = setOf(BrandTextRole.BRAND_TITLE),
            ),
        )
    }

    @Test
    fun providedFontIsUsedForAnEnabledRole() {
        assertEquals(
            FontSource.PROVIDED,
            resolveBrandFont(
                enabled = true,
                fontProvided = true,
                role = BrandTextRole.INVITE_DIGITS,
                appliesTo = all,
            ),
        )
    }
}
