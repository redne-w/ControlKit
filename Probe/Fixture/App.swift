import OSLog
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        Logger(subsystem: "dev.controlkit.fixture", category: "fixture")
            .notice("ControlKit fixture launched")
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: HomeController())
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

final class HomeController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "ControlKit fixture"
        view.backgroundColor = .systemBackground
        let button = UIButton(type: .system)
        button.setTitle("Open details", for: .normal)
        button.accessibilityIdentifier = "fixture.open"
        button.addTarget(self, action: #selector(openDetails), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func openDetails() {
        navigationController?.pushViewController(DetailsController(), animated: true)
    }
}

final class DetailsController: UIViewController {
    private let counter = UILabel()
    private let field = UITextField()
    private let unlabeledField = UITextField()
    private let secureField = UITextField()
    private var count = 0
    private let launchID = UUID().uuidString

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Details"
        view.backgroundColor = .systemBackground
        let scroll = UIScrollView()
        scroll.accessibilityIdentifier = "fixture.scroll"
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .onDrag
        view.addSubview(scroll)
        let stack = UIStackView(arrangedSubviews: controls())
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.leadingAnchor,
                constant: 24),
            stack.trailingAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.trailingAnchor,
                constant: -24),
            stack.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor,
                constant: -24),
            stack.widthAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
        ])
    }

    private func controls() -> [UIView] {
        counter.text = "Count: 0"
        counter.accessibilityIdentifier = "fixture.counter"
        let incrementButton = button(
            "Increment", id: "fixture.increment", action: #selector(increment)
        )
        field.borderStyle = .roundedRect
        field.placeholder = "Type here"
        field.accessibilityIdentifier = "fixture.input"
        unlabeledField.borderStyle = .roundedRect
        unlabeledField.placeholder = "Unlabeled endpoint"
        secureField.borderStyle = .roundedRect
        secureField.isSecureTextEntry = true
        secureField.text = "fixed-test-secret"
        secureField.accessibilityIdentifier = "fixture.secure"
        let dismissButton = button(
            "Dismiss keyboard", id: "fixture.dismiss", action: #selector(dismissKeyboard)
        )
        let crashButton = button(
            "Crash fixture", id: "fixture.crash", action: #selector(crashFixture)
        )
        let identity = UILabel()
        identity.text = launchID
        identity.accessibilityIdentifier = "fixture.identity"
        var views: [UIView] = [
            counter, incrementButton, field, unlabeledField, secureField, dismissButton,
            crashButton, identity,
        ]
        for index in 0..<12 {
            let label = UILabel()
            label.text = "Scrollable row \(index)"
            label.heightAnchor.constraint(equalToConstant: 64).isActive = true
            views.append(label)
        }
        views.append(button("Bottom reached", id: "fixture.bottom", action: #selector(increment)))
        views.append(button("Duplicate A", id: "fixture.duplicate", action: #selector(increment)))
        views.append(button("Duplicate B", id: "fixture.duplicate", action: #selector(increment)))
        return views
    }

    private func button(_ title: String, id: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.accessibilityIdentifier = id
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func increment() {
        count += 1
        counter.text = "Count: \(count)"
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    @objc private func crashFixture() {
        fatalError("Intentional fixture crash")
    }
}
