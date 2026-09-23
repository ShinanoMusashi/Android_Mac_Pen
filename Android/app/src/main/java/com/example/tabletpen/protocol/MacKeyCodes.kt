package com.example.tabletpen.protocol

/**
 * macOS virtual key codes (Carbon HIToolbox Events.h) sent over KEY_EVENT.
 * The Mac posts these directly as CGEvent key events, so Android is the source
 * of truth for what key is pressed. Only the keys we actually use are listed.
 */
object MacKeyCodes {
    // Modifier bitmask (KEY_EVENT modifiers byte)
    const val MOD_SHIFT = 0x01
    const val MOD_CONTROL = 0x02
    const val MOD_OPTION = 0x04
    const val MOD_COMMAND = 0x08

    // Letters
    const val A = 0; const val B = 11; const val C = 8; const val D = 2
    const val E = 14; const val F = 3; const val G = 5; const val H = 4
    const val I = 34; const val J = 38; const val K = 40; const val L = 37
    const val M = 46; const val N = 45; const val O = 31; const val P = 35
    const val Q = 12; const val R = 15; const val S = 1; const val T = 17
    const val U = 32; const val V = 9; const val W = 13; const val X = 7
    const val Y = 16; const val Z = 6

    // Digits
    const val D1 = 18; const val D2 = 19; const val D3 = 20; const val D4 = 21
    const val D5 = 23; const val D6 = 22; const val D7 = 26; const val D8 = 28
    const val D9 = 25; const val D0 = 29

    // Whitespace / editing
    const val RETURN = 36
    const val TAB = 48
    const val SPACE = 49
    const val DELETE = 51      // Backspace
    const val ESCAPE = 53
    const val FORWARD_DELETE = 117

    // Arrows
    const val LEFT = 123
    const val RIGHT = 124
    const val DOWN = 125
    const val UP = 126

    // Modifier keys (as keys, e.g. hold Shift to sprint)
    const val SHIFT = 56
    const val CONTROL = 59
    const val OPTION = 58
    const val COMMAND = 55
}
