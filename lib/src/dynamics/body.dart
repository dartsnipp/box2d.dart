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
 * A rigid body. These are created via World.createBody.
 *
 * @author Daniel Murphy
 */
class Body {
  static const int e_islandFlag = 0x0001;
  static const int e_awakeFlag = 0x0002;
  static const int e_autoSleepFlag = 0x0004;
  static const int e_bulletFlag = 0x0008;
  static const int e_fixedRotationFlag = 0x0010;
  static const int e_activeFlag = 0x0020;
  static const int e_toiFlag = 0x0040;

  BodyType m_type = BodyType.STATIC;

  int m_flags = 0;

  int m_islandIndex = 0;

  /**
   * The body origin transform.
   */
  final Transform m_xf = new Transform.zero();
  /**
   * The previous transform for particle simulation
   */
  final Transform m_xf0 = new Transform.zero();

  /**
   * The swept motion for CCD
   */
  final Sweep m_sweep = new Sweep();

  /// the linear velocity of the center of mass
  final Vector2 _linearVelocity = new Vector2.zero();
  double _angularVelocity = 0.0;

  final Vector2 m_force = new Vector2.zero();
  double m_torque = 0.0;

  World m_world;
  Body m_prev;
  Body m_next;

  Fixture m_fixtureList;
  int m_fixtureCount = 0;

  JointEdge m_jointList;
  ContactEdge m_contactList;

  double _mass = 0.0,
      m_invMass = 0.0;

  // Rotational inertia about the center of mass.
  double m_I = 0.0,
      m_invI = 0.0;

  double m_linearDamping = 0.0;
  double angularDamping = 0.0;
  double m_gravityScale = 0.0;

  double m_sleepTime = 0.0;

  /// Use this to store your application specific data.
  Object userData;

  Body(final BodyDef bd, this.m_world) {
    assert(bd.position.isValid());
    assert(bd.linearVelocity.isValid());
    assert(bd.gravityScale >= 0.0);
    assert(bd.angularDamping >= 0.0);
    assert(bd.linearDamping >= 0.0);

    m_flags = 0;

    if (bd.bullet) {
      m_flags |= e_bulletFlag;
    }
    if (bd.fixedRotation) {
      m_flags |= e_fixedRotationFlag;
    }
    if (bd.allowSleep) {
      m_flags |= e_autoSleepFlag;
    }
    if (bd.awake) {
      m_flags |= e_awakeFlag;
    }
    if (bd.active) {
      m_flags |= e_activeFlag;
    }

    m_xf.p.set(bd.position);
    m_xf.q.setAngle(bd.angle);

    m_sweep.localCenter.setZero();
    m_sweep.c0.set(m_xf.p);
    m_sweep.c.set(m_xf.p);
    m_sweep.a0 = bd.angle;
    m_sweep.a = bd.angle;
    m_sweep.alpha0 = 0.0;

    m_jointList = null;
    m_contactList = null;
    m_prev = null;
    m_next = null;

    _linearVelocity.set(bd.linearVelocity);
    _angularVelocity = bd.angularVelocity;

    m_linearDamping = bd.linearDamping;
    angularDamping = bd.angularDamping;
    m_gravityScale = bd.gravityScale;

    m_force.setZero();

    m_sleepTime = 0.0;

    m_type = bd.type;

    if (m_type == BodyType.DYNAMIC) {
      _mass = 1.0;
      m_invMass = 1.0;
    } else {
      _mass = 0.0;
      m_invMass = 0.0;
    }

    m_I = 0.0;
    m_invI = 0.0;

    userData = bd.userData;

    m_fixtureList = null;
    m_fixtureCount = 0;
  }

  /**
   * Creates a fixture and attach it to this body. Use this function if you need to set some fixture
   * parameters, like friction. Otherwise you can create the fixture directly from a shape. If the
   * density is non-zero, this function automatically updates the mass of the body. Contacts are not
   * created until the next time step.
   *
   * @param def the fixture definition.
   * @warning This function is locked during callbacks.
   */
  Fixture createFixtureFromFixtureDef(FixtureDef def) {
    assert(m_world.isLocked() == false);

    if (m_world.isLocked() == true) {
      return null;
    }

    Fixture fixture = new Fixture();
    fixture.create(this, def);

    if ((m_flags & e_activeFlag) == e_activeFlag) {
      BroadPhase broadPhase = m_world.m_contactManager.m_broadPhase;
      fixture.createProxies(broadPhase, m_xf);
    }

    fixture.m_next = m_fixtureList;
    m_fixtureList = fixture;
    ++m_fixtureCount;

    fixture.m_body = this;

    // Adjust mass properties if needed.
    if (fixture.m_density > 0.0) {
      resetMassData();
    }

    // Let the world know we have a new fixture. This will cause new contacts
    // to be created at the beginning of the next time step.
    m_world.m_flags |= World.NEW_FIXTURE;

    return fixture;
  }

  final FixtureDef _fixDef = new FixtureDef();

  /**
   * Creates a fixture from a shape and attach it to this body. This is a convenience function. Use
   * FixtureDef if you need to set parameters like friction, restitution, user data, or filtering.
   * If the density is non-zero, this function automatically updates the mass of the body.
   *
   * @param shape the shape to be cloned.
   * @param density the shape density (set to zero for static bodies).
   * @warning This function is locked during callbacks.
   */
  Fixture createFixtureFromShape(Shape shape, [double density = 0.0]) {
    _fixDef.shape = shape;
    _fixDef.density = density;

    return createFixtureFromFixtureDef(_fixDef);
  }

  /**
   * Destroy a fixture. This removes the fixture from the broad-phase and destroys all contacts
   * associated with this fixture. This will automatically adjust the mass of the body if the body
   * is dynamic and the fixture has positive density. All fixtures attached to a body are implicitly
   * destroyed when the body is destroyed.
   *
   * @param fixture the fixture to be removed.
   * @warning This function is locked during callbacks.
   */
  void destroyFixture(Fixture fixture) {
    assert(m_world.isLocked() == false);
    if (m_world.isLocked() == true) {
      return;
    }

    assert(fixture.m_body == this);

    // Remove the fixture from this body's singly linked list.
    assert(m_fixtureCount > 0);
    Fixture node = m_fixtureList;
    Fixture last = null; // java change
    bool found = false;
    while (node != null) {
      if (node == fixture) {
        node = fixture.m_next;
        found = true;
        break;
      }
      last = node;
      node = node.m_next;
    }

    // You tried to remove a shape that is not attached to this body.
    assert(found);

    // java change, remove it from the list
    if (last == null) {
      m_fixtureList = fixture.m_next;
    } else {
      last.m_next = fixture.m_next;
    }

    // Destroy any contacts associated with the fixture.
    ContactEdge edge = m_contactList;
    while (edge != null) {
      Contact c = edge.contact;
      edge = edge.next;

      Fixture fixtureA = c.fixtureA;
      Fixture fixtureB = c.fixtureB;

      if (fixture == fixtureA || fixture == fixtureB) {
        // This destroys the contact and removes it from
        // this body's contact list.
        m_world.m_contactManager.destroy(c);
      }
    }

    if ((m_flags & e_activeFlag) == e_activeFlag) {
      BroadPhase broadPhase = m_world.m_contactManager.m_broadPhase;
      fixture.destroyProxies(broadPhase);
    }

    fixture.destroy();
    fixture.m_body = null;
    fixture.m_next = null;
    fixture = null;

    --m_fixtureCount;

    // Reset the mass data.
    resetMassData();
  }

  /**
   * Set the position of the body's origin and rotation. This breaks any contacts and wakes the
   * other bodies. Manipulating a body's transform may cause non-physical behavior. Note: contacts
   * are updated on the next call to World.step().
   *
   * @param position the world position of the body's local origin.
   * @param angle the world rotation in radians.
   */
  void setTransform(Vector2 position, double angle) {
    assert(m_world.isLocked() == false);
    if (m_world.isLocked() == true) {
      return;
    }

    m_xf.q.setAngle(angle);
    m_xf.p.set(position);

    // m_sweep.c0 = m_sweep.c = Mul(m_xf, m_sweep.localCenter);
    Transform.mulToOutUnsafeVec2(m_xf, m_sweep.localCenter, m_sweep.c);
    m_sweep.a = angle;

    m_sweep.c0.set(m_sweep.c);
    m_sweep.a0 = m_sweep.a;

    BroadPhase broadPhase = m_world.m_contactManager.m_broadPhase;
    for (Fixture f = m_fixtureList; f != null; f = f.m_next) {
      f.synchronize(broadPhase, m_xf, m_xf);
    }
  }

  /**
   * Get the body transform for the body's origin.
   *
   * @return the world transform of the body's origin.
   */
  Transform getTransform() {
    return m_xf;
  }

  /**
   * Get the world body origin position. Do not modify.
   *
   * @return the world position of the body's origin.
   */
  Vector2 get position => m_xf.p;

  /**
   * Get the angle in radians.
   *
   * @return the current world rotation angle in radians.
   */
  double getAngle() {
    return m_sweep.a;
  }

  /**
   * Get the world position of the center of mass. Do not modify.
   */
  Vector2 get worldCenter => m_sweep.c;

  /**
   * Get the local position of the center of mass. Do not modify.
   */
  Vector2 getLocalCenter() {
    return m_sweep.localCenter;
  }

  /**
   * Set the linear velocity of the center of mass.
   *
   * @param v the new linear velocity of the center of mass.
   */
  void set linearVelocity(Vector2 v) {
    if (m_type == BodyType.STATIC) {
      return;
    }

    if (Vector2.dot(v, v) > 0.0) {
      setAwake(true);
    }

    _linearVelocity.set(v);
  }

  /**
   * Get the linear velocity of the center of mass. Do not modify, instead use
   * {@link #setLinearVelocity(Vec2)}.
   *
   * @return the linear velocity of the center of mass.
   */
  Vector2 get linearVelocity => _linearVelocity;

  /**
   * Set the angular velocity.
   *
   * @param omega the new angular velocity in radians/second.
   */
  void set angularVelocity(double w) {
    if (m_type == BodyType.STATIC) {
      return;
    }

    if (w * w > 0.0) {
      setAwake(true);
    }

    _angularVelocity = w;
  }

  /**
   * Get the angular velocity.
   *
   * @return the angular velocity in radians/second.
   */
  double get angularVelocity {
    return _angularVelocity;
  }

  /**
   * Get the gravity scale of the body.
   *
   * @return
   */
  double getGravityScale() {
    return m_gravityScale;
  }

  /**
   * Set the gravity scale of the body.
   *
   * @param gravityScale
   */
  void setGravityScale(double gravityScale) {
    this.m_gravityScale = gravityScale;
  }

  /**
   * Apply a force at a world point. If the force is not applied at the center of mass, it will
   * generate a torque and affect the angular velocity. This wakes up the body.
   *
   * @param force the world force vector, usually in Newtons (N).
   * @param point the world position of the point of application.
   */
  void applyForce(Vector2 force, Vector2 point) {
    if (m_type != BodyType.DYNAMIC) {
      return;
    }

    if (isAwake() == false) {
      setAwake(true);
    }

    // m_force.addLocal(force);
    // Vec2 temp = tltemp.get();
    // temp.set(point).subLocal(m_sweep.c);
    // m_torque += Vec2.cross(temp, force);

    m_force.x += force.x;
    m_force.y += force.y;

    m_torque +=
        (point.x - m_sweep.c.x) * force.y - (point.y - m_sweep.c.y) * force.x;
  }

  /**
   * Apply a force to the center of mass. This wakes up the body.
   *
   * @param force the world force vector, usually in Newtons (N).
   */
  void applyForceToCenter(Vector2 force) {
    if (m_type != BodyType.DYNAMIC) {
      return;
    }

    if (isAwake() == false) {
      setAwake(true);
    }

    m_force.x += force.x;
    m_force.y += force.y;
  }

  /**
   * Apply a torque. This affects the angular velocity without affecting the linear velocity of the
   * center of mass. This wakes up the body.
   *
   * @param torque about the z-axis (out of the screen), usually in N-m.
   */
  void applyTorque(double torque) {
    if (m_type != BodyType.DYNAMIC) {
      return;
    }

    if (isAwake() == false) {
      setAwake(true);
    }

    m_torque += torque;
  }

  /**
   * Apply an impulse at a point. This immediately modifies the velocity. It also modifies the
   * angular velocity if the point of application is not at the center of mass. This wakes up the
   * body if 'wake' is set to true. If the body is sleeping and 'wake' is false, then there is no
   * effect.
   *
   * @param impulse the world impulse vector, usually in N-seconds or kg-m/s.
   * @param point the world position of the point of application.
   * @param wake also wake up the body
   */
  void applyLinearImpulse(Vector2 impulse, Vector2 point, bool wake) {
    if (m_type != BodyType.DYNAMIC) {
      return;
    }

    if (!isAwake()) {
      if (wake) {
        setAwake(true);
      } else {
        return;
      }
    }

    _linearVelocity.x += impulse.x * m_invMass;
    _linearVelocity.y += impulse.y * m_invMass;

    _angularVelocity += m_invI *
        ((point.x - m_sweep.c.x) * impulse.y -
            (point.y - m_sweep.c.y) * impulse.x);
  }

  /**
   * Apply an angular impulse.
   *
   * @param impulse the angular impulse in units of kg*m*m/s
   */
  void applyAngularImpulse(double impulse) {
    if (m_type != BodyType.DYNAMIC) {
      return;
    }

    if (isAwake() == false) {
      setAwake(true);
    }
    _angularVelocity += m_invI * impulse;
  }

  /**
   * Get the total mass of the body.
   *
   * @return the mass, usually in kilograms (kg).
   */
  double get mass => _mass;

  /**
   * Get the central rotational inertia of the body.
   *
   * @return the rotational inertia, usually in kg-m^2.
   */
  double getInertia() {
    return m_I +
        _mass *
            (m_sweep.localCenter.x * m_sweep.localCenter.x +
                m_sweep.localCenter.y * m_sweep.localCenter.y);
  }

  /**
   * Get the mass data of the body. The rotational inertia is relative to the center of mass.
   *
   * @return a struct containing the mass, inertia and center of the body.
   */
  void getMassData(MassData data) {
    // data.mass = m_mass;
    // data.I = m_I + m_mass * Vec2.dot(m_sweep.localCenter, m_sweep.localCenter);
    // data.center.set(m_sweep.localCenter);

    data.mass = _mass;
    data.I = m_I +
        _mass *
            (m_sweep.localCenter.x * m_sweep.localCenter.x +
                m_sweep.localCenter.y * m_sweep.localCenter.y);
    data.center.x = m_sweep.localCenter.x;
    data.center.y = m_sweep.localCenter.y;
  }

  /**
   * Set the mass properties to override the mass properties of the fixtures. Note that this changes
   * the center of mass position. Note that creating or destroying fixtures can also alter the mass.
   * This function has no effect if the body isn't dynamic.
   *
   * @param massData the mass properties.
   */
  void setMassData(MassData massData) {
    // TODO_ERIN adjust linear velocity and torque to account for movement of center.
    assert(m_world.isLocked() == false);
    if (m_world.isLocked() == true) {
      return;
    }

    if (m_type != BodyType.DYNAMIC) {
      return;
    }

    m_invMass = 0.0;
    m_I = 0.0;
    m_invI = 0.0;

    _mass = massData.mass;
    if (_mass <= 0.0) {
      _mass = 1.0;
    }

    m_invMass = 1.0 / _mass;

    if (massData.I > 0.0 && (m_flags & e_fixedRotationFlag) == 0.0) {
      m_I = massData.I - _mass * Vector2.dot(massData.center, massData.center);
      assert(m_I > 0.0);
      m_invI = 1.0 / m_I;
    }

    final Vector2 oldCenter = m_world.getPool().popVec2();
    // Move center of mass.
    oldCenter.set(m_sweep.c);
    m_sweep.localCenter.set(massData.center);
    // m_sweep.c0 = m_sweep.c = Mul(m_xf, m_sweep.localCenter);
    Transform.mulToOutUnsafeVec2(m_xf, m_sweep.localCenter, m_sweep.c0);
    m_sweep.c.set(m_sweep.c0);

    // Update center of mass velocity.
    // m_linearVelocity += Cross(m_angularVelocity, m_sweep.c - oldCenter);
    final Vector2 temp = m_world.getPool().popVec2();
    temp.set(m_sweep.c).sub(oldCenter);
    Vector2.crossToOutDblVec2(_angularVelocity, temp, temp);
    _linearVelocity.add(temp);

    m_world.getPool().pushVec2(2);
  }

  final MassData _pmd = new MassData();

  /**
   * This resets the mass properties to the sum of the mass properties of the fixtures. This
   * normally does not need to be called unless you called setMassData to override the mass and you
   * later want to reset the mass.
   */
  void resetMassData() {
    // Compute mass data from shapes. Each shape has its own density.
    _mass = 0.0;
    m_invMass = 0.0;
    m_I = 0.0;
    m_invI = 0.0;
    m_sweep.localCenter.setZero();

    // Static and kinematic bodies have zero mass.
    if (m_type == BodyType.STATIC || m_type == BodyType.KINEMATIC) {
      // m_sweep.c0 = m_sweep.c = m_xf.position;
      m_sweep.c0.set(m_xf.p);
      m_sweep.c.set(m_xf.p);
      m_sweep.a0 = m_sweep.a;
      return;
    }

    assert(m_type == BodyType.DYNAMIC);

    // Accumulate mass over all fixtures.
    final Vector2 localCenter = m_world.getPool().popVec2();
    localCenter.setZero();
    final Vector2 temp = m_world.getPool().popVec2();
    final MassData massData = _pmd;
    for (Fixture f = m_fixtureList; f != null; f = f.m_next) {
      if (f.m_density == 0.0) {
        continue;
      }
      f.getMassData(massData);
      _mass += massData.mass;
      // center += massData.mass * massData.center;
      temp.set(massData.center).mul(massData.mass);
      localCenter.add(temp);
      m_I += massData.I;
    }

    // Compute center of mass.
    if (_mass > 0.0) {
      m_invMass = 1.0 / _mass;
      localCenter.mul(m_invMass);
    } else {
      // Force all dynamic bodies to have a positive mass.
      _mass = 1.0;
      m_invMass = 1.0;
    }

    if (m_I > 0.0 && (m_flags & e_fixedRotationFlag) == 0.0) {
      // Center the inertia about the center of mass.
      m_I -= _mass * Vector2.dot(localCenter, localCenter);
      assert(m_I > 0.0);
      m_invI = 1.0 / m_I;
    } else {
      m_I = 0.0;
      m_invI = 0.0;
    }

    Vector2 oldCenter = m_world.getPool().popVec2();
    // Move center of mass.
    oldCenter.set(m_sweep.c);
    m_sweep.localCenter.set(localCenter);
    // m_sweep.c0 = m_sweep.c = Mul(m_xf, m_sweep.localCenter);
    Transform.mulToOutUnsafeVec2(m_xf, m_sweep.localCenter, m_sweep.c0);
    m_sweep.c.set(m_sweep.c0);

    // Update center of mass velocity.
    // m_linearVelocity += Cross(m_angularVelocity, m_sweep.c - oldCenter);
    temp.set(m_sweep.c).sub(oldCenter);

    final Vector2 temp2 = oldCenter;
    Vector2.crossToOutUnsafeDblVec2(_angularVelocity, temp, temp2);
    _linearVelocity.add(temp2);

    m_world.getPool().pushVec2(3);
  }

  /**
   * Get the world coordinates of a point given the local coordinates.
   *
   * @param localPoint a point on the body measured relative the the body's origin.
   * @return the same point expressed in world coordinates.
   */
  Vector2 getWorldPoint(Vector2 localPoint) {
    Vector2 v = new Vector2.zero();
    getWorldPointToOut(localPoint, v);
    return v;
  }

  void getWorldPointToOut(Vector2 localPoint, Vector2 out) {
    Transform.mulToOutVec2(m_xf, localPoint, out);
  }

  /**
   * Get the world coordinates of a vector given the local coordinates.
   *
   * @param localVector a vector fixed in the body.
   * @return the same vector expressed in world coordinates.
   */
  Vector2 getWorldVector(Vector2 localVector) {
    Vector2 out = new Vector2.zero();
    getWorldVectorToOut(localVector, out);
    return out;
  }

  void getWorldVectorToOut(Vector2 localVector, Vector2 out) {
    Rot.mulToOut(m_xf.q, localVector, out);
  }

  void getWorldVectorToOutUnsafe(Vector2 localVector, Vector2 out) {
    Rot.mulToOutUnsafe(m_xf.q, localVector, out);
  }

  /**
   * Gets a local point relative to the body's origin given a world point.
   *
   * @param a point in world coordinates.
   * @return the corresponding local point relative to the body's origin.
   */
  Vector2 getLocalPoint(Vector2 worldPoint) {
    Vector2 out = new Vector2.zero();
    getLocalPointToOut(worldPoint, out);
    return out;
  }

  void getLocalPointToOut(Vector2 worldPoint, Vector2 out) {
    Transform.mulTransToOutVec2(m_xf, worldPoint, out);
  }

  /**
   * Gets a local vector given a world vector.
   *
   * @param a vector in world coordinates.
   * @return the corresponding local vector.
   */
  Vector2 getLocalVector(Vector2 worldVector) {
    Vector2 out = new Vector2.zero();
    getLocalVectorToOut(worldVector, out);
    return out;
  }

  void getLocalVectorToOut(Vector2 worldVector, Vector2 out) {
    Rot.mulTransVec2(m_xf.q, worldVector, out);
  }

  void getLocalVectorToOutUnsafe(Vector2 worldVector, Vector2 out) {
    Rot.mulTransUnsafeVec2(m_xf.q, worldVector, out);
  }

  /**
   * Get the world linear velocity of a world point attached to this body.
   *
   * @param a point in world coordinates.
   * @return the world velocity of a point.
   */
  Vector2 getLinearVelocityFromWorldPoint(Vector2 worldPoint) {
    Vector2 out = new Vector2.zero();
    getLinearVelocityFromWorldPointToOut(worldPoint, out);
    return out;
  }

  void getLinearVelocityFromWorldPointToOut(Vector2 worldPoint, Vector2 out) {
    final double tempX = worldPoint.x - m_sweep.c.x;
    final double tempY = worldPoint.y - m_sweep.c.y;
    out.x = -_angularVelocity * tempY + _linearVelocity.x;
    out.y = _angularVelocity * tempX + _linearVelocity.y;
  }

  /**
   * Get the world velocity of a local point.
   *
   * @param a point in local coordinates.
   * @return the world velocity of a point.
   */
  Vector2 getLinearVelocityFromLocalPoint(Vector2 localPoint) {
    Vector2 out = new Vector2.zero();
    getLinearVelocityFromLocalPointToOut(localPoint, out);
    return out;
  }

  void getLinearVelocityFromLocalPointToOut(Vector2 localPoint, Vector2 out) {
    getWorldPointToOut(localPoint, out);
    getLinearVelocityFromWorldPointToOut(out, out);
  }

  /** Get the linear damping of the body. */
  double getLinearDamping() {
    return m_linearDamping;
  }

  /** Set the linear damping of the body. */
  void setLinearDamping(double linearDamping) {
    m_linearDamping = linearDamping;
  }

  BodyType getType() {
    return m_type;
  }

  /**
   * Set the type of this body. This may alter the mass and velocity.
   *
   * @param type
   */
  void setType(BodyType type) {
    assert(m_world.isLocked() == false);
    if (m_world.isLocked() == true) {
      return;
    }

    if (m_type == type) {
      return;
    }

    m_type = type;

    resetMassData();

    if (m_type == BodyType.STATIC) {
      _linearVelocity.setZero();
      _angularVelocity = 0.0;
      m_sweep.a0 = m_sweep.a;
      m_sweep.c0.set(m_sweep.c);
      synchronizeFixtures();
    }

    setAwake(true);

    m_force.setZero();
    m_torque = 0.0;

    // Delete the attached contacts.
    ContactEdge ce = m_contactList;
    while (ce != null) {
      ContactEdge ce0 = ce;
      ce = ce.next;
      m_world.m_contactManager.destroy(ce0.contact);
    }
    m_contactList = null;

    // Touch the proxies so that new contacts will be created (when appropriate)
    BroadPhase broadPhase = m_world.m_contactManager.m_broadPhase;
    for (Fixture f = m_fixtureList; f != null; f = f.m_next) {
      int proxyCount = f.m_proxyCount;
      for (int i = 0; i < proxyCount; ++i) {
        broadPhase.touchProxy(f.m_proxies[i].proxyId);
      }
    }
  }

  /** Is this body treated like a bullet for continuous collision detection? */
  bool isBullet() {
    return (m_flags & e_bulletFlag) == e_bulletFlag;
  }

  /** Should this body be treated like a bullet for continuous collision detection? */
  void setBullet(bool flag) {
    if (flag) {
      m_flags |= e_bulletFlag;
    } else {
      m_flags &= ~e_bulletFlag;
    }
  }

  /**
   * You can disable sleeping on this body. If you disable sleeping, the body will be woken.
   *
   * @param flag
   */
  void setSleepingAllowed(bool flag) {
    if (flag) {
      m_flags |= e_autoSleepFlag;
    } else {
      m_flags &= ~e_autoSleepFlag;
      setAwake(true);
    }
  }

  /**
   * Is this body allowed to sleep
   *
   * @return
   */
  bool isSleepingAllowed() {
    return (m_flags & e_autoSleepFlag) == e_autoSleepFlag;
  }

  /**
   * Set the sleep state of the body. A sleeping body has very low CPU cost.
   *
   * @param flag set to true to put body to sleep, false to wake it.
   * @param flag
   */
  void setAwake(bool flag) {
    if (flag) {
      if ((m_flags & e_awakeFlag) == 0) {
        m_flags |= e_awakeFlag;
        m_sleepTime = 0.0;
      }
    } else {
      m_flags &= ~e_awakeFlag;
      m_sleepTime = 0.0;
      _linearVelocity.setZero();
      _angularVelocity = 0.0;
      m_force.setZero();
      m_torque = 0.0;
    }
  }

  /**
   * Get the sleeping state of this body.
   *
   * @return true if the body is awake.
   */
  bool isAwake() {
    return (m_flags & e_awakeFlag) == e_awakeFlag;
  }

  /**
   * Set the active state of the body. An inactive body is not simulated and cannot be collided with
   * or woken up. If you pass a flag of true, all fixtures will be added to the broad-phase. If you
   * pass a flag of false, all fixtures will be removed from the broad-phase and all contacts will
   * be destroyed. Fixtures and joints are otherwise unaffected. You may continue to create/destroy
   * fixtures and joints on inactive bodies. Fixtures on an inactive body are implicitly inactive
   * and will not participate in collisions, ray-casts, or queries. Joints connected to an inactive
   * body are implicitly inactive. An inactive body is still owned by a World object and remains in
   * the body list.
   *
   * @param flag
   */
  void setActive(bool flag) {
    assert(m_world.isLocked() == false);

    if (flag == isActive()) {
      return;
    }

    if (flag) {
      m_flags |= e_activeFlag;

      // Create all proxies.
      BroadPhase broadPhase = m_world.m_contactManager.m_broadPhase;
      for (Fixture f = m_fixtureList; f != null; f = f.m_next) {
        f.createProxies(broadPhase, m_xf);
      }

      // Contacts are created the next time step.
    } else {
      m_flags &= ~e_activeFlag;

      // Destroy all proxies.
      BroadPhase broadPhase = m_world.m_contactManager.m_broadPhase;
      for (Fixture f = m_fixtureList; f != null; f = f.m_next) {
        f.destroyProxies(broadPhase);
      }

      // Destroy the attached contacts.
      ContactEdge ce = m_contactList;
      while (ce != null) {
        ContactEdge ce0 = ce;
        ce = ce.next;
        m_world.m_contactManager.destroy(ce0.contact);
      }
      m_contactList = null;
    }
  }

  /**
   * Get the active state of the body.
   *
   * @return
   */
  bool isActive() {
    return (m_flags & e_activeFlag) == e_activeFlag;
  }

  /**
   * Set this body to have fixed rotation. This causes the mass to be reset.
   *
   * @param flag
   */
  void setFixedRotation(bool flag) {
    if (flag) {
      m_flags |= e_fixedRotationFlag;
    } else {
      m_flags &= ~e_fixedRotationFlag;
    }

    resetMassData();
  }

  /**
   * Does this body have fixed rotation?
   *
   * @return
   */
  bool isFixedRotation() {
    return (m_flags & e_fixedRotationFlag) == e_fixedRotationFlag;
  }

  /** Get the list of all fixtures attached to this body. */
  Fixture getFixtureList() {
    return m_fixtureList;
  }

  /** Get the list of all joints attached to this body. */
  JointEdge getJointList() {
    return m_jointList;
  }

  /**
   * Get the list of all contacts attached to this body.
   *
   * @warning this list changes during the time step and you may miss some collisions if you don't
   *          use ContactListener.
   */
  ContactEdge getContactList() {
    return m_contactList;
  }

  /** Get the next body in the world's body list. */
  Body getNext() {
    return m_next;
  }

  /**
   * Get the parent world of this body.
   */
  World getWorld() {
    return m_world;
  }

  // djm pooling
  final Transform _pxf = new Transform.zero();

  void synchronizeFixtures() {
    final Transform xf1 = _pxf;
    // xf1.position = m_sweep.c0 - Mul(xf1.R, m_sweep.localCenter);

    // xf1.q.set(m_sweep.a0);
    // Rot.mulToOutUnsafe(xf1.q, m_sweep.localCenter, xf1.p);
    // xf1.p.mulLocal(-1).addLocal(m_sweep.c0);
    // inlined:
    xf1.q.s = MathUtils.sin(m_sweep.a0);
    xf1.q.c = MathUtils.cos(m_sweep.a0);
    xf1.p.x = m_sweep.c0.x -
        xf1.q.c * m_sweep.localCenter.x +
        xf1.q.s * m_sweep.localCenter.y;
    xf1.p.y = m_sweep.c0.y -
        xf1.q.s * m_sweep.localCenter.x -
        xf1.q.c * m_sweep.localCenter.y;
    // end inline

    for (Fixture f = m_fixtureList; f != null; f = f.m_next) {
      f.synchronize(m_world.m_contactManager.m_broadPhase, xf1, m_xf);
    }
  }

  void synchronizeTransform() {
    // m_xf.q.set(m_sweep.a);
    //
    // // m_xf.position = m_sweep.c - Mul(m_xf.R, m_sweep.localCenter);
    // Rot.mulToOutUnsafe(m_xf.q, m_sweep.localCenter, m_xf.p);
    // m_xf.p.mulLocal(-1).addLocal(m_sweep.c);
    //
    m_xf.q.s = MathUtils.sin(m_sweep.a);
    m_xf.q.c = MathUtils.cos(m_sweep.a);
    Rot q = m_xf.q;
    Vector2 v = m_sweep.localCenter;
    m_xf.p.x = m_sweep.c.x - q.c * v.x + q.s * v.y;
    m_xf.p.y = m_sweep.c.y - q.s * v.x - q.c * v.y;
  }

  /**
   * This is used to prevent connected bodies from colliding. It may lie, depending on the
   * collideConnected flag.
   *
   * @param other
   * @return
   */
  bool shouldCollide(Body other) {
    // At least one body should be dynamic.
    if (m_type != BodyType.DYNAMIC && other.m_type != BodyType.DYNAMIC) {
      return false;
    }

    // Does a joint prevent collision?
    for (JointEdge jn = m_jointList; jn != null; jn = jn.next) {
      if (jn.other == other) {
        if (jn.joint.getCollideConnected() == false) {
          return false;
        }
      }
    }

    return true;
  }

  void advance(double t) {
    // Advance to the new safe time. This doesn't sync the broad-phase.
    m_sweep.advance(t);
    m_sweep.c.set(m_sweep.c0);
    m_sweep.a = m_sweep.a0;
    m_xf.q.setAngle(m_sweep.a);
    // m_xf.position = m_sweep.c - Mul(m_xf.R, m_sweep.localCenter);
    Rot.mulToOutUnsafe(m_xf.q, m_sweep.localCenter, m_xf.p);
    m_xf.p.mul(-1.0).add(m_sweep.c);
  }

  String toString() {
    return "Body[pos: ${position} linVel: ${linearVelocity} angVel: ${angularVelocity}]";
  }
}
