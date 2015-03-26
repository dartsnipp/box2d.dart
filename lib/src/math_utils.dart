/*******************************************************************************
 * Copyright (c) 2015, Daniel Murphy, Google
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *  * Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *  * Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 ******************************************************************************/

library box2d.math_utils;

import 'dart:math' as Math;
import 'dart:typed_data';
import 'package:vector_math/vector_math_64.dart' show Vector2;

import 'settings.dart' as Settings;

export 'dart:math' show cos, atan2;

const double TWOPI = Math.PI * 2.0;

double distanceSquared(Vector2 v1, Vector2 v2) {
  double dx = (v1.x - v2.x);
  double dy = (v1.y - v2.y);
  return dx * dx + dy * dy;
}

double distance(Vector2 v1, Vector2 v2) => Math.sqrt(distanceSquared(v1, v2));

/** Returns the closest value to 'a' that is in between 'low' and 'high' */
double clampDouble(final double a, final double low, final double high) =>
    Math.max(low, Math.min(a, high));

Vector2 clampVec2(final Vector2 a, final Vector2 low, final Vector2 high) {
  final Vector2 min = new Vector2.zero();
  min.x = a.x < high.x ? a.x : high.x;
  min.y = a.y < high.y ? a.y : high.y;
  min.x = low.x > min.x ? low.x : min.x;
  min.y = low.y > min.y ? low.y : min.y;
  return min;
}

/**
 * Given a value within the range specified by [fromMin] and [fromMax],
 * returns a value with the same relative position in the range specified
 * from [toMin] and [toMax]. For example, given a [val] of 2 in the
 * "from range" of 0-4, and a "to range" of 10-20, would return 15.
 */
double translateAndScale(
    double val, double fromMin, double fromMax, double toMin, double toMax) {
  final double mult = (val - fromMin) / (fromMax - fromMin);
  final double res = toMin + mult * (toMax - toMin);
  return res;
}

bool approxEquals(num expected, num actual, [num tolerance = null]) {
  if (tolerance == null) {
    tolerance = (expected / 1e4).abs();
  }
  return ((expected - actual).abs() <= tolerance);
}

Vector2 crossDblVec2(double s, Vector2 a) {
  return new Vector2(-s * a.y, s * a.x);
}

bool vector2Equals(Vector2 a, Vector2 b) {
  if ((a == null) || (b == null)) return false;
  if (identical(a, b)) return true;
  if (a is! Vector2 || b is! Vector2) return false;
  return ((a.x == b.x) && (a.y == b.y));
}

bool vector2IsValid(Vector2 v) {
  return !v.x.isNaN && !v.x.isInfinite && !v.y.isNaN && !v.y.isInfinite;
}

double sin(double x) {
  if (Settings.SINCOS_LUT_ENABLED) {
    return _sinLUT(x);
  } else {
    return Math.sin(x);
  }
}

// Optimize sin and cos. Note: using LUT worsens performance.
final Float64List _sinTable = _initSinLUT();

Float64List _initSinLUT() {
  var table = new Float64List(Settings.SINCOS_LUT_LENGTH);
  for (int i = 0; i < Settings.SINCOS_LUT_LENGTH; i++) {
    table[i] = Math.sin(i * Settings.SINCOS_LUT_PRECISION);
  }
  return table;
}

double _sinLUT(double x) {
  x %= TWOPI;

  if (x < 0) {
    x += TWOPI;
  }

  if (Settings.SINCOS_LUT_LERP) {
    x /= Settings.SINCOS_LUT_PRECISION;

    final int index = x.toInt();

    if (index != 0) {
      x %= index;
    }

    // the next index is 0
    if (index == Settings.SINCOS_LUT_LENGTH - 1) {
      return ((1 - x) * _sinTable[index] + x * _sinTable[0]);
    } else {
      return ((1 - x) * _sinTable[index] + x * _sinTable[index + 1]);
    }
  } else {
    return _sinTable[(x / Settings.SINCOS_LUT_PRECISION).round() %
        Settings.SINCOS_LUT_LENGTH];
  }
}