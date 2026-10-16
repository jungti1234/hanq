import Foundation
extension AutoInputPlan {
 static let caseCount = 100
 static let identifier = "korean-composer-100-v1"
 static func cases(count: Int = caseCount) -> [AutoTestCase] {
  precondition((1...caseCount).contains(count))
  let samples: [(String, [(UInt16, Bool)])] = [("안녕하세요. 오늘도 좋은 하루입니다.",[(2,false),(40,false),(1,false),(1,false),(32,false),(2,false),(5,false),(40,false),(17,false),(35,false),(2,false),(16,false),(47,false),(49,false),(2,false),(4,false),(1,false),(46,false),(3,false),(14,false),(4,false),(49,false),(13,false),(4,false),(5,false),(2,false),(46,false),(1,false),(49,false),(5,false),(40,false),(3,false),(45,false),(2,false),(37,false),(12,false),(1,false),(37,false),(14,false),(40,false),(47,false)]),
("천천히 입력하다가 빠르게 이어 씁니다.",[(8,false),(38,false),(1,false),(8,false),(38,false),(1,false),(5,false),(37,false),(49,false),(2,false),(37,false),(12,false),(3,false),(32,false),(15,false),(5,false),(40,false),(14,false),(40,false),(15,false),(40,false),(49,false),(12,true),(40,false),(3,false),(46,false),(15,false),(35,false),(49,false),(2,false),(37,false),(2,false),(38,false),(49,false),(17,true),(46,false),(12,false),(1,false),(37,false),(14,false),(40,false),(47,false)]),
("왼쪽과 오른쪽을 오가며 확인합니다.",[(2,false),(4,false),(37,false),(1,false),(13,true),(4,false),(15,false),(15,false),(4,false),(40,false),(49,false),(2,false),(4,false),(3,false),(46,false),(1,false),(13,true),(4,false),(15,false),(2,false),(46,false),(3,false),(49,false),(2,false),(4,false),(15,false),(40,false),(0,false),(32,false),(49,false),(5,false),(4,false),(40,false),(15,false),(2,false),(37,false),(1,false),(5,false),(40,false),(12,false),(1,false),(37,false),(14,false),(40,false),(47,false)]),
("짧게 쓰고 다시 고칩니다.",[(13,true),(40,false),(3,false),(12,false),(15,false),(35,false),(49,false),(17,true),(46,false),(15,false),(4,false),(49,false),(14,false),(40,false),(17,false),(37,false),(49,false),(15,false),(4,false),(8,false),(37,false),(12,false),(1,false),(37,false),(14,false),(40,false),(47,false)]),
("문장 중간의 글자도 그대로 남아야 합니다.",[(0,false),(45,false),(1,false),(13,false),(40,false),(2,false),(49,false),(13,false),(45,false),(2,false),(15,false),(40,false),(1,false),(2,false),(46,false),(37,false),(49,false),(15,false),(46,false),(3,false),(13,false),(40,false),(14,false),(4,false),(49,false),(15,false),(46,false),(14,false),(31,false),(3,false),(4,false),(49,false),(1,false),(40,false),(0,false),(2,false),(40,false),(2,false),(34,false),(49,false),(5,false),(40,false),(12,false),(1,false),(37,false),(14,false),(40,false),(47,false)])]
  var result = [AutoTestCase]()
  // Preserve the original 30-case prefix. Every sentence is tested 20 times;
  // 40/20/8ms groups contain 35/35/30 cases, including verified clear/overwrite.
  for _ in 0..<((count + 14) / 15) { for gap in [0.04, 0.02, 0.008] { for sample in samples {
   if result.count == count { return result }
   result.append(AutoTestCase(id: result.count + 1, expected: sample.0, keys: sample.1.map { AutoTestKey(code: $0.0, shift: $0.1) }, gap: gap, overwrite: !result.isEmpty && result.count % 2 == 1))
  } } }
  return result
 }
}
