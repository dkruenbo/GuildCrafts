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
3. Use `/gc sim 5` to generate simulated data for testing without a full guild

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

Check `spec/improvements.md` for the roadmap. Good first contributions:
- Bug fixes
- Locale/translation support
- UI improvements
- Documentation improvements

## Pull Request Guidelines

- Keep PRs focused on a single change
- Describe what the PR does and why
- Test in-game before submitting (use `/gc sim` if you don't have guild data)
- Update documentation if your change affects user-facing behavior

## Bug Reports

Open an issue with:
- What you expected to happen
- What actually happened
- Steps to reproduce
- Your WoW client version

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
