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

part of box2d;

/**
 * Java-specific class for returning edge results
 */
class _EdgeResults {
  double separation = 0.0;
  int edgeIndex = 0;
}

/**
 * Used for computing contact manifolds.
 */
class ClipVertex {
  final Vector2 v = new Vector2.zero();
  final ContactID id = new ContactID();

  void set(final ClipVertex cv) {
    Vector2 v1 = cv.v;
    v.x = v1.x;
    v.y = v1.y;
    ContactID c = cv.id;
    id.indexA = c.indexA;
    id.indexB = c.indexB;
    id.typeA = c.typeA;
    id.typeB = c.typeB;
  }
}

/**
 * This is used for determining the state of contact points.
 *
 * @author Daniel Murphy
 */
enum PointState {
  /**
   * point does not exist
   */
  NULL_STATE,
  /**
   * point was added in the update
   */
  ADD_STATE,
  /**
   * point persisted across the update
   */
  PERSIST_STATE,
  /**
   * point was removed in the update
   */
  REMOVE_STATE
}

/**
 * This structure is used to keep track of the best separating axis.
 */

enum EPAxisType { UNKNOWN, EDGE_A, EDGE_B }

class EPAxis {
  EPAxisType type = EPAxisType.UNKNOWN;
  int index = 0;
  double separation = 0.0;
}

/**
 * This holds polygon B expressed in frame A.
 */
class TempPolygon {
  final List<Vector2> vertices = new List<Vector2>(Settings.maxPolygonVertices);
  final List<Vector2> normals = new List<Vector2>(Settings.maxPolygonVertices);
  int count = 0;

  TempPolygon() {
    for (int i = 0; i < vertices.length; i++) {
      vertices[i] = new Vector2.zero();
      normals[i] = new Vector2.zero();
    }
  }
}

/**
 * Reference face used for clipping
 */
class _ReferenceFace {
  int i1 = 0, i2 = 0;
  final Vector2 v1 = new Vector2.zero();
  final Vector2 v2 = new Vector2.zero();
  final Vector2 normal = new Vector2.zero();

  final Vector2 sideNormal1 = new Vector2.zero();
  double sideOffset1 = 0.0;

  final Vector2 sideNormal2 = new Vector2.zero();
  double sideOffset2 = 0.0;
}

/**
 * Functions used for computing contact points, distance queries, and TOI queries. Collision methods
 * are non-static for pooling speed, retrieve a collision object from the {@link SingletonPool}.
 * Should not be finalructed.
 */
class Collision {
  static const int NULL_FEATURE = 0x3FFFFFFF; // Integer.MAX_VALUE;

  final IWorldPool _pool;

  Collision(this._pool) {
    _incidentEdge[0] = new ClipVertex();
    _incidentEdge[1] = new ClipVertex();
    _clipPoints1[0] = new ClipVertex();
    _clipPoints1[1] = new ClipVertex();
    _clipPoints2[0] = new ClipVertex();
    _clipPoints2[1] = new ClipVertex();
  }

  final DistanceInput _input = new DistanceInput();
  final SimplexCache _cache = new SimplexCache();
  final DistanceOutput _output = new DistanceOutput();

  /**
   * Determine if two generic shapes overlap.
   *
   * @param shapeA
   * @param shapeB
   * @param xfA
   * @param xfB
   * @return
   */
  bool testOverlap(Shape shapeA, int indexA, Shape shapeB, int indexB,
      Transform xfA, Transform xfB) {
    _input.proxyA.set(shapeA, indexA);
    _input.proxyB.set(shapeB, indexB);
    _input.transformA.set(xfA);
    _input.transformB.set(xfB);
    _input.useRadii = true;

    _cache.count = 0;

    _pool.getDistance().distance(_output, _cache, _input);
    // djm note: anything significant about 10.0f?
    return _output.distance < 10.0 * Settings.EPSILON;
  }

  /**
   * Compute the point states given two manifolds. The states pertain to the transition from
   * manifold1 to manifold2. So state1 is either persist or remove while state2 is either add or
   * persist.
   *
   * @param state1
   * @param state2
   * @param manifold1
   * @param manifold2
   */
  static void getPointStates(
      final List<PointState> state1,
      final List<PointState> state2,
      final Manifold manifold1,
      final Manifold manifold2) {
    for (int i = 0; i < Settings.maxManifoldPoints; i++) {
      state1[i] = PointState.NULL_STATE;
      state2[i] = PointState.NULL_STATE;
    }

    // Detect persists and removes.
    for (int i = 0; i < manifold1.pointCount; i++) {
      ContactID id = manifold1.points[i].id;

      state1[i] = PointState.REMOVE_STATE;

      for (int j = 0; j < manifold2.pointCount; j++) {
        if (manifold2.points[j].id.isEqual(id)) {
          state1[i] = PointState.PERSIST_STATE;
          break;
        }
      }
    }

    // Detect persists and adds
    for (int i = 0; i < manifold2.pointCount; i++) {
      ContactID id = manifold2.points[i].id;

      state2[i] = PointState.ADD_STATE;

      for (int j = 0; j < manifold1.pointCount; j++) {
        if (manifold1.points[j].id.isEqual(id)) {
          state2[i] = PointState.PERSIST_STATE;
          break;
        }
      }
    }
  }

  /**
   * Clipping for contact manifolds. Sutherland-Hodgman clipping.
   *
   * @param vOut
   * @param vIn
   * @param normal
   * @param offset
   * @return
   */
  static int clipSegmentToLine(
      final List<ClipVertex> vOut,
      final List<ClipVertex> vIn,
      final Vector2 normal,
      double offset,
      int vertexIndexA) {
    // Start with no _output points
    int numOut = 0;
    final ClipVertex vIn0 = vIn[0];
    final ClipVertex vIn1 = vIn[1];
    final Vector2 vIn0v = vIn0.v;
    final Vector2 vIn1v = vIn1.v;

    // Calculate the distance of end points to the line
    double distance0 = normal.dot(vIn0v) - offset;
    double distance1 = normal.dot(vIn1v) - offset;

    // If the points are behind the plane
    if (distance0 <= 0.0) {
      vOut[numOut++].set(vIn0);
    }
    if (distance1 <= 0.0) {
      vOut[numOut++].set(vIn1);
    }

    // If the points are on different sides of the plane
    if (distance0 * distance1 < 0.0) {
      // Find intersection point of edge and plane
      double interp = distance0 / (distance0 - distance1);

      ClipVertex vOutNO = vOut[numOut];
      // vOut[numOut].v = vIn[0].v + interp * (vIn[1].v - vIn[0].v);
      vOutNO.v.x = vIn0v.x + interp * (vIn1v.x - vIn0v.x);
      vOutNO.v.y = vIn0v.y + interp * (vIn1v.y - vIn0v.y);

      // VertexA is hitting edgeB.
      vOutNO.id.indexA = vertexIndexA & 0xFF;
      vOutNO.id.indexB = vIn0.id.indexB;
      vOutNO.id.typeA = ContactIDType.VERTEX.index & 0xFF;
      vOutNO.id.typeB = ContactIDType.FACE.index & 0xFF;
      ++numOut;
    }

    return numOut;
  }

  // #### COLLISION STUFF (not from collision.h or collision.cpp) ####

  // djm pooling
  static Vector2 _d = new Vector2.zero();

  /**
   * Compute the collision manifold between two circles.
   *
   * @param manifold
   * @param circle1
   * @param xfA
   * @param circle2
   * @param xfB
   */
  void collideCircles(Manifold manifold, final CircleShape circle1,
      final Transform xfA, final CircleShape circle2, final Transform xfB) {
    manifold.pointCount = 0;
    // before inline:
    // Transform.mulToOut(xfA, circle1.p, pA);
    // Transform.mulToOut(xfB, circle2.p, pB);
    // d.set(pB).subLocal(pA);
    // double distSqr = d.x * d.x + d.y * d.y;

    // after inline:
    Vector2 circle1p = circle1.p;
    Vector2 circle2p = circle2.p;
    double pAx = (xfA.q.c * circle1p.x - xfA.q.s * circle1p.y) + xfA.p.x;
    double pAy = (xfA.q.s * circle1p.x + xfA.q.c * circle1p.y) + xfA.p.y;
    double pBx = (xfB.q.c * circle2p.x - xfB.q.s * circle2p.y) + xfB.p.x;
    double pBy = (xfB.q.s * circle2p.x + xfB.q.c * circle2p.y) + xfB.p.y;
    double dx = pBx - pAx;
    double dy = pBy - pAy;
    double distSqr = dx * dx + dy * dy;
    // end inline

    final double radius = circle1.radius + circle2.radius;
    if (distSqr > radius * radius) {
      return;
    }

    manifold.type = ManifoldType.CIRCLES;
    manifold.localPoint.setFrom(circle1p);
    manifold.localNormal.setZero();
    manifold.pointCount = 1;

    manifold.points[0].localPoint.setFrom(circle2p);
    manifold.points[0].id.zero();
  }

  // djm pooling, and from above

  /**
   * Compute the collision manifold between a polygon and a circle.
   *
   * @param manifold
   * @param polygon
   * @param xfA
   * @param circle
   * @param xfB
   */
  void collidePolygonAndCircle(Manifold manifold, final PolygonShape polygon,
      final Transform xfA, final CircleShape circle, final Transform xfB) {
    manifold.pointCount = 0;
    // Vec2 v = circle.p;

    // Compute circle position in the frame of the polygon.
    // before inline:
    // Transform.mulToOutUnsafe(xfB, circle.p, c);
    // Transform.mulTransToOut(xfA, c, cLocal);
    // final double cLocalx = cLocal.x;
    // final double cLocaly = cLocal.y;
    // after inline:
    final Vector2 circlep = circle.p;
    final Rot xfBq = xfB.q;
    final Rot xfAq = xfA.q;
    final double cx = (xfBq.c * circlep.x - xfBq.s * circlep.y) + xfB.p.x;
    final double cy = (xfBq.s * circlep.x + xfBq.c * circlep.y) + xfB.p.y;
    final double px = cx - xfA.p.x;
    final double py = cy - xfA.p.y;
    final double cLocalx = (xfAq.c * px + xfAq.s * py);
    final double cLocaly = (-xfAq.s * px + xfAq.c * py);
    // end inline

    // Find the min separating edge.
    int normalIndex = 0;
    double separation = -double.MAX_FINITE;
    final double radius = polygon.radius + circle.radius;
    final int vertexCount = polygon.count;
    double s;
    final List<Vector2> vertices = polygon.vertices;
    final List<Vector2> normals = polygon.normals;

    for (int i = 0; i < vertexCount; i++) {
      // before inline
      // temp.set(cLocal).subLocal(vertices[i]);
      // double s = Vec2.dot(normals[i], temp);
      // after inline
      final Vector2 vertex = vertices[i];
      final double tempx = cLocalx - vertex.x;
      final double tempy = cLocaly - vertex.y;
      s = normals[i].x * tempx + normals[i].y * tempy;

      if (s > radius) {
        // early out
        return;
      }

      if (s > separation) {
        separation = s;
        normalIndex = i;
      }
    }

    // Vertices that subtend the incident face.
    final int vertIndex1 = normalIndex;
    final int vertIndex2 = vertIndex1 + 1 < vertexCount ? vertIndex1 + 1 : 0;
    final Vector2 v1 = vertices[vertIndex1];
    final Vector2 v2 = vertices[vertIndex2];

    // If the center is inside the polygon ...
    if (separation < Settings.EPSILON) {
      manifold.pointCount = 1;
      manifold.type = ManifoldType.FACE_A;

      // before inline:
      // manifold._localNormal.set(normals[normalIndex]);
      // manifold.localPoint.set(v1).addLocal(v2).mulLocal(.5f);
      // manifold.points[0].localPoint.set(circle.p);
      // after inline:
      final Vector2 normal = normals[normalIndex];
      manifold.localNormal.x = normal.x;
      manifold.localNormal.y = normal.y;
      manifold.localPoint.x = (v1.x + v2.x) * .5;
      manifold.localPoint.y = (v1.y + v2.y) * .5;
      final ManifoldPoint mpoint = manifold.points[0];
      mpoint.localPoint.x = circlep.x;
      mpoint.localPoint.y = circlep.y;
      mpoint.id.zero();
      // end inline

      return;
    }

    // Compute barycentric coordinates
    // before inline:
    // temp.set(cLocal).subLocal(v1);
    // temp2.set(v2).subLocal(v1);
    // double u1 = Vec2.dot(temp, temp2);
    // temp.set(cLocal).subLocal(v2);
    // temp2.set(v1).subLocal(v2);
    // double u2 = Vec2.dot(temp, temp2);
    // after inline:
    final double tempX = cLocalx - v1.x;
    final double tempY = cLocaly - v1.y;
    final double temp2X = v2.x - v1.x;
    final double temp2Y = v2.y - v1.y;
    final double u1 = tempX * temp2X + tempY * temp2Y;

    final double temp3X = cLocalx - v2.x;
    final double temp3Y = cLocaly - v2.y;
    final double temp4X = v1.x - v2.x;
    final double temp4Y = v1.y - v2.y;
    final double u2 = temp3X * temp4X + temp3Y * temp4Y;
    // end inline

    if (u1 <= 0.0) {
      // inlined
      final double dx = cLocalx - v1.x;
      final double dy = cLocaly - v1.y;
      if (dx * dx + dy * dy > radius * radius) {
        return;
      }

      manifold.pointCount = 1;
      manifold.type = ManifoldType.FACE_A;
      // before inline:
      // manifold._localNormal.set(cLocal).subLocal(v1);
      // after inline:
      manifold.localNormal.x = cLocalx - v1.x;
      manifold.localNormal.y = cLocaly - v1.y;
      // end inline
      manifold.localNormal.normalize();
      manifold.localPoint.setFrom(v1);
      manifold.points[0].localPoint.setFrom(circlep);
      manifold.points[0].id.zero();
    } else if (u2 <= 0.0) {
      // inlined
      final double dx = cLocalx - v2.x;
      final double dy = cLocaly - v2.y;
      if (dx * dx + dy * dy > radius * radius) {
        return;
      }

      manifold.pointCount = 1;
      manifold.type = ManifoldType.FACE_A;
      // before inline:
      // manifold._localNormal.set(cLocal).subLocal(v2);
      // after inline:
      manifold.localNormal.x = cLocalx - v2.x;
      manifold.localNormal.y = cLocaly - v2.y;
      // end inline
      manifold.localNormal.normalize();
      manifold.localPoint.setFrom(v2);
      manifold.points[0].localPoint.setFrom(circlep);
      manifold.points[0].id.zero();
    } else {
      // Vec2 faceCenter = 0.5f * (v1 + v2);
      // (temp is faceCenter)
      // before inline:
      // temp.set(v1).addLocal(v2).mulLocal(.5f);
      //
      // temp2.set(cLocal).subLocal(temp);
      // separation = Vec2.dot(temp2, normals[vertIndex1]);
      // if (separation > radius) {
      // return;
      // }
      // after inline:
      final double fcx = (v1.x + v2.x) * .5;
      final double fcy = (v1.y + v2.y) * .5;

      final double tx = cLocalx - fcx;
      final double ty = cLocaly - fcy;
      final Vector2 normal = normals[vertIndex1];
      separation = tx * normal.x + ty * normal.y;
      if (separation > radius) {
        return;
      }
      // end inline

      manifold.pointCount = 1;
      manifold.type = ManifoldType.FACE_A;
      manifold.localNormal.setFrom(normals[vertIndex1]);
      manifold.localPoint.x = fcx; // (faceCenter)
      manifold.localPoint.y = fcy;
      manifold.points[0].localPoint.setFrom(circlep);
      manifold.points[0].id.zero();
    }
  }

  // djm pooling, and from above
  final Vector2 _temp = new Vector2.zero();
  final Transform _xf = new Transform.zero();
  final Vector2 _n = new Vector2.zero();
  final Vector2 _v1 = new Vector2.zero();

  /**
   * Find the max separation between poly1 and poly2 using edge normals from poly1.
   *
   * @param edgeIndex
   * @param poly1
   * @param xf1
   * @param poly2
   * @param xf2
   * @return
   */
  void findMaxSeparation(_EdgeResults results, final PolygonShape poly1,
      final Transform xf1, final PolygonShape poly2, final Transform xf2) {
    int count1 = poly1.count;
    int count2 = poly2.count;
    List<Vector2> n1s = poly1.normals;
    List<Vector2> v1s = poly1.vertices;
    List<Vector2> v2s = poly2.vertices;

    Transform.mulTransToOutUnsafe(xf2, xf1, _xf);
    final Rot xfq = _xf.q;

    int bestIndex = 0;
    double maxSeparation = -double.MAX_FINITE;
    for (int i = 0; i < count1; i++) {
      // Get poly1 normal in frame2.
      Rot.mulToOutUnsafe(xfq, n1s[i], _n);
      Transform.mulToOutUnsafeVec2(_xf, v1s[i], _v1);

      // Find deepest point for normal i.
      double si = double.MAX_FINITE;
      for (int j = 0; j < count2; ++j) {
        Vector2 v2sj = v2s[j];
        double sij = _n.x * (v2sj.x - _v1.x) + _n.y * (v2sj.y - _v1.y);
        if (sij < si) {
          si = sij;
        }
      }

      if (si > maxSeparation) {
        maxSeparation = si;
        bestIndex = i;
      }
    }

    results.edgeIndex = bestIndex;
    results.separation = maxSeparation;
  }

  void findIncidentEdge(
      final List<ClipVertex> c,
      final PolygonShape poly1,
      final Transform xf1,
      int edge1,
      final PolygonShape poly2,
      final Transform xf2) {
    int count1 = poly1.count;
    final List<Vector2> normals1 = poly1.normals;

    int count2 = poly2.count;
    final List<Vector2> vertices2 = poly2.vertices;
    final List<Vector2> normals2 = poly2.normals;

    assert(0 <= edge1 && edge1 < count1);

    final ClipVertex c0 = c[0];
    final ClipVertex c1 = c[1];
    final Rot xf1q = xf1.q;
    final Rot xf2q = xf2.q;

    // Get the normal of the reference edge in poly2's frame.
    // Vec2 normal1 = MulT(xf2.R, Mul(xf1.R, normals1[edge1]));
    // before inline:
    // Rot.mulToOutUnsafe(xf1.q, normals1[edge1], normal1); // temporary
    // Rot.mulTrans(xf2.q, normal1, normal1);
    // after inline:
    final Vector2 v = normals1[edge1];
    final double tempx = xf1q.c * v.x - xf1q.s * v.y;
    final double tempy = xf1q.s * v.x + xf1q.c * v.y;
    final double normal1x = xf2q.c * tempx + xf2q.s * tempy;
    final double normal1y = -xf2q.s * tempx + xf2q.c * tempy;

    // end inline

    // Find the incident edge on poly2.
    int index = 0;
    double minDot = double.MAX_FINITE;
    for (int i = 0; i < count2; ++i) {
      Vector2 b = normals2[i];
      double dot = normal1x * b.x + normal1y * b.y;
      if (dot < minDot) {
        minDot = dot;
        index = i;
      }
    }

    // Build the clip vertices for the incident edge.
    int i1 = index;
    int i2 = i1 + 1 < count2 ? i1 + 1 : 0;

    // c0.v = Mul(xf2, vertices2[i1]);
    Vector2 v1 = vertices2[i1];
    Vector2 out = c0.v;
    out.x = (xf2q.c * v1.x - xf2q.s * v1.y) + xf2.p.x;
    out.y = (xf2q.s * v1.x + xf2q.c * v1.y) + xf2.p.y;
    c0.id.indexA = edge1 & 0xFF;
    c0.id.indexB = i1 & 0xFF;
    c0.id.typeA = ContactIDType.FACE.index & 0xFF;
    c0.id.typeB = ContactIDType.VERTEX.index & 0xFF;

    // c1.v = Mul(xf2, vertices2[i2]);
    Vector2 v2 = vertices2[i2];
    Vector2 out1 = c1.v;
    out1.x = (xf2q.c * v2.x - xf2q.s * v2.y) + xf2.p.x;
    out1.y = (xf2q.s * v2.x + xf2q.c * v2.y) + xf2.p.y;
    c1.id.indexA = edge1 & 0xFF;
    c1.id.indexB = i2 & 0xFF;
    c1.id.typeA = ContactIDType.FACE.index & 0xFF;
    c1.id.typeB = ContactIDType.VERTEX.index & 0xFF;
  }

  final _EdgeResults _results1 = new _EdgeResults();
  final _EdgeResults results2 = new _EdgeResults();
  final List<ClipVertex> _incidentEdge = new List<ClipVertex>(2);
  final Vector2 _localTangent = new Vector2.zero();
  final Vector2 _localNormal = new Vector2.zero();
  final Vector2 _planePoint = new Vector2.zero();
  final Vector2 _tangent = new Vector2.zero();
  final Vector2 _v11 = new Vector2.zero();
  final Vector2 _v12 = new Vector2.zero();
  final List<ClipVertex> _clipPoints1 = new List<ClipVertex>(2);
  final List<ClipVertex> _clipPoints2 = new List<ClipVertex>(2);

  /**
   * Compute the collision manifold between two polygons.
   *
   * @param manifold
   * @param polygon1
   * @param xf1
   * @param polygon2
   * @param xf2
   */
  void collidePolygons(Manifold manifold, final PolygonShape polyA,
      final Transform xfA, final PolygonShape polyB, final Transform xfB) {
    // Find edge normal of max separation on A - return if separating axis is found
    // Find edge normal of max separation on B - return if separation axis is found
    // Choose reference edge as min(minA, minB)
    // Find incident edge
    // Clip

    // The normal points from 1 to 2

    manifold.pointCount = 0;
    double totalRadius = polyA.radius + polyB.radius;

    findMaxSeparation(_results1, polyA, xfA, polyB, xfB);
    if (_results1.separation > totalRadius) {
      return;
    }

    findMaxSeparation(results2, polyB, xfB, polyA, xfA);
    if (results2.separation > totalRadius) {
      return;
    }

    PolygonShape poly1; // reference polygon
    PolygonShape poly2; // incident polygon
    Transform xf1, xf2;
    int edge1; // reference edge
    bool flip;
    final double k_tol = 0.1 * Settings.linearSlop;

    if (results2.separation > _results1.separation + k_tol) {
      poly1 = polyB;
      poly2 = polyA;
      xf1 = xfB;
      xf2 = xfA;
      edge1 = results2.edgeIndex;
      manifold.type = ManifoldType.FACE_B;
      flip = true;
    } else {
      poly1 = polyA;
      poly2 = polyB;
      xf1 = xfA;
      xf2 = xfB;
      edge1 = _results1.edgeIndex;
      manifold.type = ManifoldType.FACE_A;
      flip = false;
    }
    final Rot xf1q = xf1.q;

    findIncidentEdge(_incidentEdge, poly1, xf1, edge1, poly2, xf2);

    int count1 = poly1.count;
    final List<Vector2> vertices1 = poly1.vertices;

    final int iv1 = edge1;
    final int iv2 = edge1 + 1 < count1 ? edge1 + 1 : 0;
    _v11.setFrom(vertices1[iv1]);
    _v12.setFrom(vertices1[iv2]);
    _localTangent.x = _v12.x - _v11.x;
    _localTangent.y = _v12.y - _v11.y;
    _localTangent.normalize();

    // Vec2 _localNormal = Vec2.cross(dv, 1.0f);
    _localNormal.x = 1.0 * _localTangent.y;
    _localNormal.y = -1.0 * _localTangent.x;

    // Vec2 _planePoint = 0.5f * (_v11+ _v12);
    _planePoint.x = (_v11.x + _v12.x) * .5;
    _planePoint.y = (_v11.y + _v12.y) * .5;

    // Rot.mulToOutUnsafe(xf1.q, _localTangent, _tangent);
    _tangent.x = xf1q.c * _localTangent.x - xf1q.s * _localTangent.y;
    _tangent.y = xf1q.s * _localTangent.x + xf1q.c * _localTangent.y;

    // Vec2.crossToOutUnsafe(_tangent, 1f, normal);
    final double normalx = 1.0 * _tangent.y;
    final double normaly = -1.0 * _tangent.x;

    Transform.mulToOutVec2(xf1, _v11, _v11);
    Transform.mulToOutVec2(xf1, _v12, _v12);
    // _v11 = Mul(xf1, _v11);
    // _v12 = Mul(xf1, _v12);

    // Face offset
    // double frontOffset = Vec2.dot(normal, _v11);
    double frontOffset = normalx * _v11.x + normaly * _v11.y;

    // Side offsets, extended by polytope skin thickness.
    // double sideOffset1 = -Vec2.dot(_tangent, _v11) + totalRadius;
    // double sideOffset2 = Vec2.dot(_tangent, _v12) + totalRadius;
    double sideOffset1 =
        -(_tangent.x * _v11.x + _tangent.y * _v11.y) + totalRadius;
    double sideOffset2 =
        _tangent.x * _v12.x + _tangent.y * _v12.y + totalRadius;

    // Clip incident edge against extruded edge1 side edges.
    // ClipVertex _clipPoints1[2];
    // ClipVertex _clipPoints2[2];
    int np;

    // Clip to box side 1
    // np = ClipSegmentToLine(_clipPoints1, _incidentEdge, -sideNormal, sideOffset1);
    _tangent.negate();
    np = clipSegmentToLine(
        _clipPoints1, _incidentEdge, _tangent, sideOffset1, iv1);
    _tangent.negate();

    if (np < 2) {
      return;
    }

    // Clip to negative box side 1
    np = clipSegmentToLine(
        _clipPoints2, _clipPoints1, _tangent, sideOffset2, iv2);

    if (np < 2) {
      return;
    }

    // Now _clipPoints2 contains the clipped points.
    manifold.localNormal.setFrom(_localNormal);
    manifold.localPoint.setFrom(_planePoint);

    int pointCount = 0;
    for (int i = 0; i < Settings.maxManifoldPoints; ++i) {
      // double separation = Vec2.dot(normal, _clipPoints2[i].v) - frontOffset;
      double separation = normalx * _clipPoints2[i].v.x +
          normaly * _clipPoints2[i].v.y -
          frontOffset;

      if (separation <= totalRadius) {
        ManifoldPoint cp = manifold.points[pointCount];
        // cp.localPoint = MulT(xf2, _clipPoints2[i].v);
        Vector2 out = cp.localPoint;
        final double px = _clipPoints2[i].v.x - xf2.p.x;
        final double py = _clipPoints2[i].v.y - xf2.p.y;
        out.x = (xf2.q.c * px + xf2.q.s * py);
        out.y = (-xf2.q.s * px + xf2.q.c * py);
        cp.id.set(_clipPoints2[i].id);
        if (flip) {
          // Swap features
          cp.id.flip();
        }
        ++pointCount;
      }
    }

    manifold.pointCount = pointCount;
  }

  final Vector2 _Q = new Vector2.zero();
  final Vector2 _e = new Vector2.zero();
  final ContactID _cf = new ContactID();
  final Vector2 _e1 = new Vector2.zero();
  final Vector2 _P = new Vector2.zero();

  // Compute contact points for edge versus circle.
  // This accounts for edge connectivity.
  void collideEdgeAndCircle(Manifold manifold, final EdgeShape edgeA,
      final Transform xfA, final CircleShape circleB, final Transform xfB) {
    manifold.pointCount = 0;

    // Compute circle in frame of edge
    // Vec2 Q = MulT(xfA, Mul(xfB, circleB.p));
    Transform.mulToOutUnsafeVec2(xfB, circleB.p, _temp);
    Transform.mulTransToOutUnsafeVec2(xfA, _temp, _Q);

    final Vector2 A = edgeA.vertex1;
    final Vector2 B = edgeA.vertex2;
    _e
      ..setFrom(B)
      ..sub(A);

    // Barycentric coordinates
    double u = _e.dot(_temp
      ..setFrom(B)
      ..sub(_Q));
    double v = _e.dot(_temp
      ..setFrom(_Q)
      ..sub(A));

    double radius = edgeA.radius + circleB.radius;

    // ContactFeature cf;
    _cf.indexB = 0;
    _cf.typeB = ContactIDType.VERTEX.index & 0xFF;

    // Region A
    if (v <= 0.0) {
      final Vector2 P = A;
      _d
        ..setFrom(_Q)
        ..sub(P);
      double dd = _d.dot(_d);
      if (dd > radius * radius) {
        return;
      }

      // Is there an edge connected to A?
      if (edgeA.hasVertex0) {
        final Vector2 A1 = edgeA.vertex0;
        final Vector2 B1 = A;
        _e1
          ..setFrom(B1)
          ..sub(A1);
        double u1 = _e1.dot(_temp
          ..setFrom(B1)
          ..sub(_Q));

        // Is the circle in Region AB of the previous edge?
        if (u1 > 0.0) {
          return;
        }
      }

      _cf.indexA = 0;
      _cf.typeA = ContactIDType.VERTEX.index & 0xFF;
      manifold.pointCount = 1;
      manifold.type = ManifoldType.CIRCLES;
      manifold.localNormal.setZero();
      manifold.localPoint.setFrom(P);
      // manifold.points[0].id.key = 0;
      manifold.points[0].id.set(_cf);
      manifold.points[0].localPoint.setFrom(circleB.p);
      return;
    }

    // Region B
    if (u <= 0.0) {
      Vector2 P = B;
      _d
        ..setFrom(_Q)
        ..sub(P);
      double dd = _d.dot(_d);
      if (dd > radius * radius) {
        return;
      }

      // Is there an edge connected to B?
      if (edgeA.hasVertex3) {
        final Vector2 B2 = edgeA.vertex3;
        final Vector2 A2 = B;
        final Vector2 e2 = _e1;
        e2
          ..setFrom(B2)
          ..sub(A2);
        double v2 = e2.dot(_temp
          ..setFrom(_Q)
          ..sub(A2));

        // Is the circle in Region AB of the next edge?
        if (v2 > 0.0) {
          return;
        }
      }

      _cf.indexA = 1;
      _cf.typeA = ContactIDType.VERTEX.index & 0xFF;
      manifold.pointCount = 1;
      manifold.type = ManifoldType.CIRCLES;
      manifold.localNormal.setZero();
      manifold.localPoint.setFrom(P);
      // manifold.points[0].id.key = 0;
      manifold.points[0].id.set(_cf);
      manifold.points[0].localPoint.setFrom(circleB.p);
      return;
    }

    // Region AB
    double den = _e.dot(_e);
    assert(den > 0.0);

    // Vec2 P = (1.0f / den) * (u * A + v * B);
    _P
      ..setFrom(A)
      ..scale(u)
      ..add(_temp
        ..setFrom(B)
        ..scale(v));
    _P.scale(1.0 / den);
    _d
      ..setFrom(_Q)
      ..sub(_P);
    double dd = _d.dot(_d);
    if (dd > radius * radius) {
      return;
    }

    _n.x = -_e.y;
    _n.y = _e.x;
    if (_n.dot(_temp
          ..setFrom(_Q)
          ..sub(A)) <
        0.0) {
      _n.setValues(-_n.x, -_n.y);
    }
    _n.normalize();

    _cf.indexA = 0;
    _cf.typeA = ContactIDType.FACE.index & 0xFF;
    manifold.pointCount = 1;
    manifold.type = ManifoldType.FACE_A;
    manifold.localNormal.setFrom(_n);
    manifold.localPoint.setFrom(A);
    // manifold.points[0].id.key = 0;
    manifold.points[0].id.set(_cf);
    manifold.points[0].localPoint.setFrom(circleB.p);
  }

  final EPCollider _collider = new EPCollider();

  void collideEdgeAndPolygon(Manifold manifold, final EdgeShape edgeA,
      final Transform xfA, final PolygonShape polygonB, final Transform xfB) {
    _collider.collide(manifold, edgeA, xfA, polygonB, xfB);
  }

  /**
   * This class collides and edge and a polygon, taking into account edge adjacency.
   */
}

enum VertexType { ISOLATED, CONCAVE, CONVEX }

class EPCollider {
  final TempPolygon polygonB = new TempPolygon();

  final Transform xf = new Transform.zero();
  final Vector2 centroidB = new Vector2.zero();
  Vector2 v0 = new Vector2.zero();
  Vector2 v1 = new Vector2.zero();
  Vector2 v2 = new Vector2.zero();
  Vector2 v3 = new Vector2.zero();
  final Vector2 normal0 = new Vector2.zero();
  final Vector2 normal1 = new Vector2.zero();
  final Vector2 normal2 = new Vector2.zero();
  final Vector2 normal = new Vector2.zero();

  VertexType type1 = VertexType.ISOLATED, type2 = VertexType.ISOLATED;

  final Vector2 lowerLimit = new Vector2.zero();
  final Vector2 upperLimit = new Vector2.zero();
  double radius = 0.0;
  bool front = false;

  EPCollider() {
    for (int i = 0; i < 2; i++) {
      _ie[i] = new ClipVertex();
      _clipPoints1[i] = new ClipVertex();
      _clipPoints2[i] = new ClipVertex();
    }
  }

  final Vector2 _edge1 = new Vector2.zero();
  final Vector2 _temp = new Vector2.zero();
  final Vector2 _edge0 = new Vector2.zero();
  final Vector2 _edge2 = new Vector2.zero();
  final List<ClipVertex> _ie = new List<ClipVertex>(2);
  final List<ClipVertex> _clipPoints1 = new List<ClipVertex>(2);
  final List<ClipVertex> _clipPoints2 = new List<ClipVertex>(2);
  final _ReferenceFace _rf = new _ReferenceFace();
  final EPAxis _edgeAxis = new EPAxis();
  final EPAxis _polygonAxis = new EPAxis();

  void collide(Manifold manifold, final EdgeShape edgeA, final Transform xfA,
      final PolygonShape polygonB_, final Transform xfB) {
    Transform.mulTransToOutUnsafe(xfA, xfB, xf);
    Transform.mulToOutUnsafeVec2(xf, polygonB_.centroid, centroidB);

    v0 = edgeA.vertex0;
    v1 = edgeA.vertex1;
    v2 = edgeA.vertex2;
    v3 = edgeA.vertex3;

    bool hasVertex0 = edgeA.hasVertex0;
    bool hasVertex3 = edgeA.hasVertex3;

    _edge1
      ..setFrom(v2)
      ..sub(v1);
    _edge1.normalize();
    normal1.setValues(_edge1.y, -_edge1.x);
    double offset1 = normal1.dot(_temp
      ..setFrom(centroidB)
      ..sub(v1));
    double offset0 = 0.0, offset2 = 0.0;
    bool convex1 = false, convex2 = false;

    // Is there a preceding edge?
    if (hasVertex0) {
      _edge0
        ..setFrom(v1)
        ..sub(v0);
      _edge0.normalize();
      normal0.setValues(_edge0.y, -_edge0.x);
      convex1 = _edge0.cross(_edge1) >= 0.0;
      offset0 = normal0.dot(_temp
        ..setFrom(centroidB)
        ..sub(v0));
    }

    // Is there a following edge?
    if (hasVertex3) {
      _edge2
        ..setFrom(v3)
        ..sub(v2);
      _edge2.normalize();
      normal2.setValues(_edge2.y, -_edge2.x);
      convex2 = _edge1.cross(_edge2) > 0.0;
      offset2 = normal2.dot(_temp
        ..setFrom(centroidB)
        ..sub(v2));
    }

    // Determine front or back collision. Determine collision normal limits.
    if (hasVertex0 && hasVertex3) {
      if (convex1 && convex2) {
        front = offset0 >= 0.0 || offset1 >= 0.0 || offset2 >= 0.0;
        if (front) {
          normal.x = normal1.x;
          normal.y = normal1.y;
          lowerLimit.x = normal0.x;
          lowerLimit.y = normal0.y;
          upperLimit.x = normal2.x;
          upperLimit.y = normal2.y;
        } else {
          normal.x = -normal1.x;
          normal.y = -normal1.y;
          lowerLimit.x = -normal1.x;
          lowerLimit.y = -normal1.y;
          upperLimit.x = -normal1.x;
          upperLimit.y = -normal1.y;
        }
      } else if (convex1) {
        front = offset0 >= 0.0 || (offset1 >= 0.0 && offset2 >= 0.0);
        if (front) {
          normal.x = normal1.x;
          normal.y = normal1.y;
          lowerLimit.x = normal0.x;
          lowerLimit.y = normal0.y;
          upperLimit.x = normal1.x;
          upperLimit.y = normal1.y;
        } else {
          normal.x = -normal1.x;
          normal.y = -normal1.y;
          lowerLimit.x = -normal2.x;
          lowerLimit.y = -normal2.y;
          upperLimit.x = -normal1.x;
          upperLimit.y = -normal1.y;
        }
      } else if (convex2) {
        front = offset2 >= 0.0 || (offset0 >= 0.0 && offset1 >= 0.0);
        if (front) {
          normal.x = normal1.x;
          normal.y = normal1.y;
          lowerLimit.x = normal1.x;
          lowerLimit.y = normal1.y;
          upperLimit.x = normal2.x;
          upperLimit.y = normal2.y;
        } else {
          normal.x = -normal1.x;
          normal.y = -normal1.y;
          lowerLimit.x = -normal1.x;
          lowerLimit.y = -normal1.y;
          upperLimit.x = -normal0.x;
          upperLimit.y = -normal0.y;
        }
      } else {
        front = offset0 >= 0.0 && offset1 >= 0.0 && offset2 >= 0.0;
        if (front) {
          normal.x = normal1.x;
          normal.y = normal1.y;
          lowerLimit.x = normal1.x;
          lowerLimit.y = normal1.y;
          upperLimit.x = normal1.x;
          upperLimit.y = normal1.y;
        } else {
          normal.x = -normal1.x;
          normal.y = -normal1.y;
          lowerLimit.x = -normal2.x;
          lowerLimit.y = -normal2.y;
          upperLimit.x = -normal0.x;
          upperLimit.y = -normal0.y;
        }
      }
    } else if (hasVertex0) {
      if (convex1) {
        front = offset0 >= 0.0 || offset1 >= 0.0;
        if (front) {
          normal.x = normal1.x;
          normal.y = normal1.y;
          lowerLimit.x = normal0.x;
          lowerLimit.y = normal0.y;
          upperLimit.x = -normal1.x;
          upperLimit.y = -normal1.y;
        } else {
          normal.x = -normal1.x;
          normal.y = -normal1.y;
          lowerLimit.x = normal1.x;
          lowerLimit.y = normal1.y;
          upperLimit.x = -normal1.x;
          upperLimit.y = -normal1.y;
        }
      } else {
        front = offset0 >= 0.0 && offset1 >= 0.0;
        if (front) {
          normal.x = normal1.x;
          normal.y = normal1.y;
          lowerLimit.x = normal1.x;
          lowerLimit.y = normal1.y;
          upperLimit.x = -normal1.x;
          upperLimit.y = -normal1.y;
        } else {
          normal.x = -normal1.x;
          normal.y = -normal1.y;
          lowerLimit.x = normal1.x;
          lowerLimit.y = normal1.y;
          upperLimit.x = -normal0.x;
          upperLimit.y = -normal0.y;
        }
      }
    } else if (hasVertex3) {
      if (convex2) {
        front = offset1 >= 0.0 || offset2 >= 0.0;
        if (front) {
          normal.x = normal1.x;
          normal.y = normal1.y;
          lowerLimit.x = -normal1.x;
          lowerLimit.y = -normal1.y;
          upperLimit.x = normal2.x;
          upperLimit.y = normal2.y;
        } else {
          normal.x = -normal1.x;
          normal.y = -normal1.y;
          lowerLimit.x = -normal1.x;
          lowerLimit.y = -normal1.y;
          upperLimit.x = normal1.x;
          upperLimit.y = normal1.y;
        }
      } else {
        front = offset1 >= 0.0 && offset2 >= 0.0;
        if (front) {
          normal.x = normal1.x;
          normal.y = normal1.y;
          lowerLimit.x = -normal1.x;
          lowerLimit.y = -normal1.y;
          upperLimit.x = normal1.x;
          upperLimit.y = normal1.y;
        } else {
          normal.x = -normal1.x;
          normal.y = -normal1.y;
          lowerLimit.x = -normal2.x;
          lowerLimit.y = -normal2.y;
          upperLimit.x = normal1.x;
          upperLimit.y = normal1.y;
        }
      }
    } else {
      front = offset1 >= 0.0;
      if (front) {
        normal.x = normal1.x;
        normal.y = normal1.y;
        lowerLimit.x = -normal1.x;
        lowerLimit.y = -normal1.y;
        upperLimit.x = -normal1.x;
        upperLimit.y = -normal1.y;
      } else {
        normal.x = -normal1.x;
        normal.y = -normal1.y;
        lowerLimit.x = normal1.x;
        lowerLimit.y = normal1.y;
        upperLimit.x = normal1.x;
        upperLimit.y = normal1.y;
      }
    }

    // Get polygonB in frameA
    polygonB.count = polygonB_.count;
    for (int i = 0; i < polygonB_.count; ++i) {
      Transform.mulToOutUnsafeVec2(
          xf, polygonB_.vertices[i], polygonB.vertices[i]);
      Rot.mulToOutUnsafe(xf.q, polygonB_.normals[i], polygonB.normals[i]);
    }

    radius = 2.0 * Settings.polygonRadius;

    manifold.pointCount = 0;

    computeEdgeSeparation(_edgeAxis);

    // If no valid normal can be found than this edge should not collide.
    if (_edgeAxis.type == EPAxisType.UNKNOWN) {
      return;
    }

    if (_edgeAxis.separation > radius) {
      return;
    }

    computePolygonSeparation(_polygonAxis);
    if (_polygonAxis.type != EPAxisType.UNKNOWN &&
        _polygonAxis.separation > radius) {
      return;
    }

    // Use hysteresis for jitter reduction.
    final double k_relativeTol = 0.98;
    final double k_absoluteTol = 0.001;

    EPAxis primaryAxis;
    if (_polygonAxis.type == EPAxisType.UNKNOWN) {
      primaryAxis = _edgeAxis;
    } else if (_polygonAxis.separation >
        k_relativeTol * _edgeAxis.separation + k_absoluteTol) {
      primaryAxis = _polygonAxis;
    } else {
      primaryAxis = _edgeAxis;
    }

    final ClipVertex ie0 = _ie[0];
    final ClipVertex ie1 = _ie[1];

    if (primaryAxis.type == EPAxisType.EDGE_A) {
      manifold.type = ManifoldType.FACE_A;

      // Search for the polygon normal that is most anti-parallel to the edge normal.
      int bestIndex = 0;
      double bestValue = normal.dot(polygonB.normals[0]);
      for (int i = 1; i < polygonB.count; ++i) {
        double value = normal.dot(polygonB.normals[i]);
        if (value < bestValue) {
          bestValue = value;
          bestIndex = i;
        }
      }

      int i1 = bestIndex;
      int i2 = i1 + 1 < polygonB.count ? i1 + 1 : 0;

      ie0.v.setFrom(polygonB.vertices[i1]);
      ie0.id.indexA = 0;
      ie0.id.indexB = i1 & 0xFF;
      ie0.id.typeA = ContactIDType.FACE.index & 0xFF;
      ie0.id.typeB = ContactIDType.VERTEX.index & 0xFF;

      ie1.v.setFrom(polygonB.vertices[i2]);
      ie1.id.indexA = 0;
      ie1.id.indexB = i2 & 0xFF;
      ie1.id.typeA = ContactIDType.FACE.index & 0xFF;
      ie1.id.typeB = ContactIDType.VERTEX.index & 0xFF;

      if (front) {
        _rf.i1 = 0;
        _rf.i2 = 1;
        _rf.v1.setFrom(v1);
        _rf.v2.setFrom(v2);
        _rf.normal.setFrom(normal1);
      } else {
        _rf.i1 = 1;
        _rf.i2 = 0;
        _rf.v1.setFrom(v2);
        _rf.v2.setFrom(v1);
        _rf.normal
          ..setFrom(normal1)
          ..negate();
      }
    } else {
      manifold.type = ManifoldType.FACE_B;

      ie0.v.setFrom(v1);
      ie0.id.indexA = 0;
      ie0.id.indexB = primaryAxis.index & 0xFF;
      ie0.id.typeA = ContactIDType.VERTEX.index & 0xFF;
      ie0.id.typeB = ContactIDType.FACE.index & 0xFF;

      ie1.v.setFrom(v2);
      ie1.id.indexA = 0;
      ie1.id.indexB = primaryAxis.index & 0xFF;
      ie1.id.typeA = ContactIDType.VERTEX.index & 0xFF;
      ie1.id.typeB = ContactIDType.FACE.index & 0xFF;

      _rf.i1 = primaryAxis.index;
      _rf.i2 = _rf.i1 + 1 < polygonB.count ? _rf.i1 + 1 : 0;
      _rf.v1.setFrom(polygonB.vertices[_rf.i1]);
      _rf.v2.setFrom(polygonB.vertices[_rf.i2]);
      _rf.normal.setFrom(polygonB.normals[_rf.i1]);
    }

    _rf.sideNormal1.setValues(_rf.normal.y, -_rf.normal.x);
    _rf.sideNormal2
      ..setFrom(_rf.sideNormal1)
      ..negate();
    _rf.sideOffset1 = _rf.sideNormal1.dot(_rf.v1);
    _rf.sideOffset2 = _rf.sideNormal2.dot(_rf.v2);

    // Clip incident edge against extruded edge1 side edges.
    int np;

    // Clip to box side 1
    np = Collision.clipSegmentToLine(
        _clipPoints1, _ie, _rf.sideNormal1, _rf.sideOffset1, _rf.i1);

    if (np < Settings.maxManifoldPoints) {
      return;
    }

    // Clip to negative box side 1
    np = Collision.clipSegmentToLine(
        _clipPoints2, _clipPoints1, _rf.sideNormal2, _rf.sideOffset2, _rf.i2);

    if (np < Settings.maxManifoldPoints) {
      return;
    }

    // Now _clipPoints2 contains the clipped points.
    if (primaryAxis.type == EPAxisType.EDGE_A) {
      manifold.localNormal.setFrom(_rf.normal);
      manifold.localPoint.setFrom(_rf.v1);
    } else {
      manifold.localNormal.setFrom(polygonB_.normals[_rf.i1]);
      manifold.localPoint.setFrom(polygonB_.vertices[_rf.i1]);
    }

    int pointCount = 0;
    for (int i = 0; i < Settings.maxManifoldPoints; ++i) {
      double separation;

      separation = _rf.normal.dot(_temp
        ..setFrom(_clipPoints2[i].v)
        ..sub(_rf.v1));

      if (separation <= radius) {
        ManifoldPoint cp = manifold.points[pointCount];

        if (primaryAxis.type == EPAxisType.EDGE_A) {
          // cp.localPoint = MulT(xf, _clipPoints2[i].v);
          Transform.mulTransToOutUnsafeVec2(
              xf, _clipPoints2[i].v, cp.localPoint);
          cp.id.set(_clipPoints2[i].id);
        } else {
          cp.localPoint.setFrom(_clipPoints2[i].v);
          cp.id.typeA = _clipPoints2[i].id.typeB;
          cp.id.typeB = _clipPoints2[i].id.typeA;
          cp.id.indexA = _clipPoints2[i].id.indexB;
          cp.id.indexB = _clipPoints2[i].id.indexA;
        }

        ++pointCount;
      }
    }

    manifold.pointCount = pointCount;
  }

  void computeEdgeSeparation(EPAxis axis) {
    axis.type = EPAxisType.EDGE_A;
    axis.index = front ? 0 : 1;
    axis.separation = double.MAX_FINITE;
    double nx = normal.x;
    double ny = normal.y;

    for (int i = 0; i < polygonB.count; ++i) {
      Vector2 v = polygonB.vertices[i];
      double tempx = v.x - v1.x;
      double tempy = v.y - v1.y;
      double s = nx * tempx + ny * tempy;
      if (s < axis.separation) {
        axis.separation = s;
      }
    }
  }

  final Vector2 _perp = new Vector2.zero();
  final Vector2 _n = new Vector2.zero();

  void computePolygonSeparation(EPAxis axis) {
    axis.type = EPAxisType.UNKNOWN;
    axis.index = -1;
    axis.separation = -double.MAX_FINITE;

    _perp.x = -normal.y;
    _perp.y = normal.x;

    for (int i = 0; i < polygonB.count; ++i) {
      Vector2 normalB = polygonB.normals[i];
      Vector2 vB = polygonB.vertices[i];
      _n.x = -normalB.x;
      _n.y = -normalB.y;

      // double s1 = Vec2.dot(n, temp.set(vB).subLocal(v1));
      // double s2 = Vec2.dot(n, temp.set(vB).subLocal(v2));
      double tempx = vB.x - v1.x;
      double tempy = vB.y - v1.y;
      double s1 = _n.x * tempx + _n.y * tempy;
      tempx = vB.x - v2.x;
      tempy = vB.y - v2.y;
      double s2 = _n.x * tempx + _n.y * tempy;
      double s = Math.min(s1, s2);

      if (s > radius) {
        // No collision
        axis.type = EPAxisType.EDGE_B;
        axis.index = i;
        axis.separation = s;
        return;
      }

      // Adjacency
      if (_n.x * _perp.x + _n.y * _perp.y >= 0.0) {
        if ((_temp
                  ..setFrom(_n)
                  ..sub(upperLimit))
                .dot(normal) <
            -Settings.angularSlop) {
          continue;
        }
      } else {
        if ((_temp
                  ..setFrom(_n)
                  ..sub(lowerLimit))
                .dot(normal) <
            -Settings.angularSlop) {
          continue;
        }
      }

      if (s > axis.separation) {
        axis.type = EPAxisType.EDGE_B;
        axis.index = i;
        axis.separation = s;
      }
    }
  }
}
