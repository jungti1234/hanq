import Foundation
let name="HanQRetiredBounded-"+UUID().uuidString
let defaults=UserDefaults(suiteName:name)!
defer{defaults.removePersistentDomain(forName:name)}
for args in [["HanQ","--bounded-input-incidents"],["HanQ","--bounded-input-incidents","/private/tmp/old"],["HanQ","--bounded-input-incidents=/private/tmp/old"]] {
 precondition(!InputIncidentPreferences.launch(arguments:args,defaults:defaults).valid)
}
print("PASS retired bounded options fail explicitly")
