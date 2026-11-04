import Testing

func expectEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation) {
    do { let actual = try a(); let expected = try b(); if actual != expected { Issue.record("Values differ: \(actual) != \(expected)", sourceLocation: sourceLocation) } } catch { Issue.record(error, sourceLocation: sourceLocation) }
}
func expectTrue(_ value: @autoclosure () throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    do { let actual = try value(); if !actual { Issue.record("Expected true", sourceLocation: sourceLocation) } } catch { Issue.record(error, sourceLocation: sourceLocation) }
}
func expectFalse(_ value: @autoclosure () throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    do { let actual = try value(); if actual { Issue.record("Expected false", sourceLocation: sourceLocation) } } catch { Issue.record(error, sourceLocation: sourceLocation) }
}
func expectThrows<T>(_ value: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation) {
    do { _ = try value(); Issue.record("Expected an error", sourceLocation: sourceLocation) } catch {}
}
func expectNoThrow<T>(_ value: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation) {
    do { _ = try value() } catch { Issue.record(error, sourceLocation: sourceLocation) }
}
