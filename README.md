# Aegis ECS

A compact Entity-Component-System engine in **pure GDScript** for Godot 4.4+.
Built for simulations where thousands to tens of thousands of objects update
every frame.

No GDExtension, no C#, no third-party add-ons. No node per game object — data
lives in `Packed*Array`. Exports anywhere, iOS included.

## 📘 Documentation

- **[docs/en/](docs/en/README.md)** — full user guide (English): an introduction
  to the ECS approach, every feature with examples, the API reference, common
  mistakes, and a walk-through of a working mini-simulation.
- **[docs/uk/](docs/uk/README.md)** — the same guide in Ukrainian.

## Installation

Copy the `addons/aegis_ecs/` folder into your project. You do **not** need to
enable the plugin in the project settings. Verify:

```bash
godot --headless --script res://addons/aegis_ecs/example/minimal_example.gd
```

It should finish with the line `RESULT: OK`.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Vitalii Yurchenko.
