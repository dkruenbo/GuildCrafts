# Contributing to GuildCrafts

Thanks for your interest in contributing to GuildCrafts! This guide will help you get started.

## Getting Started

1. **Fork** the repository on GitHub
2. **Clone** your fork locally:
   ```bash
   git clone https://github.com/<your-username>/GuildCrafts.git
   ```
3. **Create a branch** for your change:
   ```bash
   git checkout -b feature/my-change
   ```
4. Make your changes, commit, and **push to your fork**:
   ```bash
   git push origin feature/my-change
   ```
5. Open a **Pull Request** against the `main` branch of this repository

## Development Setup

GuildCrafts is a World of Warcraft TBC Anniversary addon (Interface 20505, Lua 5.1).

To test locally:
1. Clone/symlink the `GuildCrafts/` folder into your WoW addons directory:
   ```
   World of Warcraft/_classic_/Interface/AddOns/GuildCrafts
   ```
2. Reload the game UI with `/reload`
3. Join a guild and open a profession window to populate local data

## Project Structure

| Folder | Contents |
|--------|----------|
| `GuildCrafts/` | The addon itself — all Lua, XML, TOC, and library files |
| `spec/` | Design documents, user guide, and improvement tracker |

## Code Style

- Use local variables where possible
- Follow existing naming conventions (camelCase for locals, PascalCase for methods)
- Add comments for non-obvious logic
- Keep functions focused — one responsibility per function

## What to Contribute

GuildCrafts is feature complete for its original scope and is in maintenance mode. No new features are currently planned, but contributions are still welcome in these areas:

- **Bug fixes** — if something behaves incorrectly, a focused fix is always welcome
- **Locale/translation support** — the multi-language system is in place but real-world edge cases still surface occasionally
- **Documentation improvements** — clearer explanations, better examples, corrected outdated information
- **Performance or correctness improvements** — if you spot something wasteful or subtly wrong in the protocol or data handling

If you have an idea for a larger feature, open an issue to discuss it first — the project may not be actively extended, but the conversation is welcome.

## Pull Request Guidelines

- Keep PRs focused on a single change
- Describe what the PR does and why
- Test in-game before submitting
- Update documentation if your change affects user-facing behavior

## Bug Reports

Open an issue with:
- What you expected to happen
- What actually happened
- Steps to reproduce
- Your WoW client version

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
