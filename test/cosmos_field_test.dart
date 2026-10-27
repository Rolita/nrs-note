import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/ui/graph/cosmos_field.dart';

void main() {
  CosmosField makeField() {
    final CosmosField field = CosmosField(allowArt: false);
    field.resize(const Size(1440, 900), 270);
    addTearDown(field.dispose);
    return field;
  }

  test('星场三层共 570 颗，重排尺寸后数量不变', () {
    final CosmosField field = makeField();
    expect(field.debugStarCount, 570);

    field.resize(const Size(1120, 720), 216);
    expect(field.debugStarCount, 570);
  });

  test('相机转动带动星场，并被平滑成有限的角速度', () {
    final CosmosField field = makeField();

    field.advance(0, 0.5);
    expect(field.debugSkySpin, closeTo(0.43, 1e-9));

    field.update(
      0.016,
      velX: 0,
      velY: 0,
      dragging: false,
      radius: 270,
    );
    expect(field.debugSkyShown, greaterThan(0));
    expect(field.debugSkyShown, lessThan(field.debugSkySpin));
    expect(field.debugSkyRate, greaterThan(0));
    expect(field.debugSkyRate, lessThanOrEqualTo(2.6));
  });

  test('惯性速度够大时，球缘持续甩出流星', () {
    final CosmosField field = makeField();

    for (int i = 0; i < 10; i++) {
      field.update(
        0.05,
        velX: 0,
        velY: 1,
        dragging: false,
        radius: 270,
      );
    }
    expect(field.debugMeteorCount, greaterThanOrEqualTo(3));
  });

  test('拖拽中不按惯性撒流星，避免方向打架', () {
    final CosmosField field = makeField();

    for (int i = 0; i < 20; i++) {
      field.update(
        0.05,
        velX: 0,
        velY: 1,
        dragging: true,
        radius: 270,
      );
    }
    expect(field.debugMeteorCount, 0);
  });

  test('流星会走完寿命并清掉', () {
    final CosmosField field = makeField();
    for (int i = 0; i < 10; i++) {
      field.update(
        0.05,
        velX: 0,
        velY: 1,
        dragging: false,
        radius: 270,
      );
    }
    expect(field.debugMeteorCount, greaterThan(0));

    for (int i = 0; i < 40; i++) {
      field.update(
        0.05,
        velX: 0,
        velY: 0,
        dragging: false,
        radius: 270,
      );
    }
    expect(field.debugMeteorCount, 0);
  });

  test('松手甩得够猛会炸一圈流星', () {
    final CosmosField field = makeField();

    field.release(0.8, 0.8, 270);
    expect(field.debugMeteorCount, greaterThanOrEqualTo(9));

    final CosmosField slow = CosmosField(allowArt: false)
      ..resize(const Size(1440, 900), 270);
    addTearDown(slow.dispose);
    slow.release(0.05, 0.05, 270);
    expect(slow.debugMeteorCount, 0);
  });

  test('横向拖过 96px 从球缘甩出一颗', () {
    final CosmosField field = makeField();

    for (int i = 0; i < 10; i++) {
      field.drag(12, 0, 270);
    }
    expect(field.debugMeteorCount, 1);
  });

  test('大彗星开场 4.5 秒出现，走完寿命后清掉', () {
    final CosmosField field = makeField();
    for (int i = 0; i < 40; i++) {
      field.update(0.1, velX: 0, velY: 0, dragging: false, radius: 270);
    }
    expect(field.debugBigCount, 0);

    for (int i = 0; i < 6; i++) {
      field.update(0.1, velX: 0, velY: 0, dragging: false, radius: 270);
    }
    expect(field.debugBigCount, 1);

    // 顺手把丝带尾巴画一遍：没有预渲染贴图时也不能崩。
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    field.paintSky(canvas, const Size(1440, 900), radius: 270);
    recorder.endRecording().dispose();

    for (int i = 0; i < 200; i++) {
      field.update(0.1, velX: 0, velY: 0, dragging: false, radius: 270);
    }
    expect(field.debugBigCount, 0);
  });

  test('没有预渲染图片时也能把天空画完', () {
    final CosmosField field = makeField();
    for (int i = 0; i < 25; i++) {
      field.update(
        0.05,
        velX: 0,
        velY: 1,
        dragging: false,
        radius: 270,
      );
    }
    field.release(0.9, 0.4, 270);

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    field.paintSky(canvas, const Size(1440, 900), radius: 270);
    field.paintMeteors(canvas, const Size(1440, 900));
    recorder.endRecording().dispose();
  });
}
