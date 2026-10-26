import 'package:flutter_test/flutter_test.dart';

import 'package:nrs/ui/graph/orb_math.dart';

/// 相机矩阵是「世界 → 相机」（行主序）：`c = M · w`。
/// 反变换是 `w = Mᵀ · c`，所以相机 x/y 轴在世界里是 M 的**行**。
///
/// 这个文件只守一件事：拿 [OrbCamera.rightX] / [OrbCamera.upX] 这三元组去乘
/// 矩阵，必须正好落在对应的相机轴上。取成列（转置用反）的话，乘出来是反方向，
/// 拖拽节点时它会朝鼠标的反面跑——静态分析看不出来，只有拖起来才发现。
void main() {
  group('OrbCamera 的相机轴', () {
    /// 把世界向量过一遍矩阵，返回相机空间坐标。
    List<double> toCamera(OrbCamera cam, List<double> w) {
      final m = cam.matrix;
      return <double>[
        m[0] * w[0] + m[1] * w[1] + m[2] * w[2],
        m[3] * w[0] + m[4] * w[1] + m[5] * w[2],
        m[6] * w[0] + m[7] * w[1] + m[8] * w[2],
      ];
    }

    void expectAxis(OrbCamera cam) {
      final right = toCamera(cam, <double>[
        cam.rightX,
        cam.rightY,
        cam.rightZ,
      ]);
      expect(right[0], closeTo(1, 1e-12), reason: 'right 应投影到相机 +x');
      expect(right[1], closeTo(0, 1e-12));
      expect(right[2], closeTo(0, 1e-12));

      final up = toCamera(cam, <double>[cam.upX, cam.upY, cam.upZ]);
      expect(up[0], closeTo(0, 1e-12));
      expect(up[1], closeTo(1, 1e-12), reason: 'up 应投影到相机 +y');
      expect(up[2], closeTo(0, 1e-12));
    }

    test('初始姿态（单位矩阵）', () {
      expectAxis(OrbCamera());
    });

    test('转过之后仍然是正交基，且方向没反过来', () {
      // 多组角度，覆盖「只绕竖轴」「只绕横轴」「斜着转」三种情况
      const cases = <List<double>>[
        <double>[0, 0.9],
        <double>[0.7, 0],
        <double>[0.4, 1.2],
        <double>[-1.1, -2.3],
        <double>[2.6, 0.35],
      ];
      for (final c in cases) {
        final cam = OrbCamera()..rotate(c[0], c[1]);
        expectAxis(cam);
      }
    });

    test('连转多次也不漂（矩阵不会退化成非正交）', () {
      final cam = OrbCamera();
      for (var i = 0; i < 200; i++) {
        cam.rotate(0.031, -0.017);
      }
      expectAxis(cam);
    });
  });
}
