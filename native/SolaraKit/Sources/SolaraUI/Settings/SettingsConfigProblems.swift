import Foundation
import Observation
import SolaraModel
import SwiftUI

@MainActor
@Observable
public final class ConfigProblemsModel {
  public static let shared = ConfigProblemsModel()

  public private(set) var problems: [ConfigProblem]
  @ObservationIgnored private let registry: ConfigProblems
  @ObservationIgnored private var token: NSObjectProtocol?

  public init(registry: ConfigProblems = .shared) {
    self.registry = registry
    problems = registry.all
    token = NotificationCenter.default.addObserver(forName: ConfigProblems.changed, object: registry, queue: nil) { [weak self] _ in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
    }
  }

  isolated deinit {
    if let token { NotificationCenter.default.removeObserver(token) }
  }

  public func refresh() {
    let next = registry.all
    if next != problems { problems = next }
  }

  public var lines: [String] {
    let location = ConfigDirectory.shared?.location
    return problems.map { $0.summary(in: location) }
  }
}

struct ConfigProblemsBanner: View {
  let model: ConfigProblemsModel

  var body: some View {
    let lines = model.lines
    if !lines.isEmpty {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.yellow)
          .font(.system(size: 15))
        VStack(alignment: .leading, spacing: 4) {
          Text(lines.count == 1 ? "A config file has a problem" : "Config files have \(lines.count) problems")
            .font(.system(size: 13, weight: .semibold))
          ForEach(Array(lines.prefix(5).enumerated()), id: \.offset) { _, line in
            Text(line)
              .font(.system(size: 12))
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          if lines.count > 5 {
            Text("and \(lines.count - 5) more")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          }
          Text("Solara keeps using the last config that worked until the file is fixed and saved.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .padding(12)
      .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.12)))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.yellow.opacity(0.35)))
      .padding(.horizontal, 20)
      .padding(.top, 10)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("settings.configProblems")
    }
  }
}
