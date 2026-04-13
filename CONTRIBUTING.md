# Contributing to ArgoCD Migration Toolkit

Thank you for your interest in contributing! This toolkit was built from real-world production experience, and we welcome contributions that make ArgoCD migrations safer and easier for everyone.

## 🎯 Ways to Contribute

- **Bug Reports**: Found an issue? Open a GitHub issue with details
- **Feature Requests**: Have an idea? Start a discussion
- **Documentation**: Improve guides, add examples, fix typos
- **Code**: Submit PRs for bug fixes or new features
- **Experience Reports**: Share your migration stories and lessons learned

## 🚀 Getting Started

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Test thoroughly (see Testing section below)
5. Commit with clear messages (`git commit -m 'Add amazing feature'`)
6. Push to your fork (`git push origin feature/amazing-feature`)
7. Open a Pull Request

## 📝 Code Guidelines

### Shell Scripts

- Use `#!/usr/bin/env bash` shebang
- Follow [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)
- Include error handling (`set -euo pipefail`)
- Add comments for complex logic
- Use meaningful variable names
- Provide `--dry-run` mode for destructive operations

### Python Scripts

- Follow [PEP 8](https://pep8.org/)
- Use type hints where appropriate
- Include docstrings for functions and classes
- Handle errors gracefully
- Support Python 3.9+

### Documentation

- Use clear, concise language
- Include code examples
- Add screenshots/diagrams where helpful
- Keep README.md up to date
- Document breaking changes

## 🧪 Testing

Before submitting a PR:

1. **Test in a non-production environment**
2. **Run dry-run mode** for all migration scripts
3. **Verify documentation** is accurate
4. **Check for sensitive data** (no credentials, real cluster names, etc.)
5. **Lint your code**:

   ```bash
   # Shell scripts
   shellcheck scripts/**/*.sh

   # Python scripts
   pylint scripts/**/*.py
   black scripts/**/*.py
   ```

## 🔒 Security

- **Never commit credentials** or secrets
- **Sanitize examples** - use `example.com`, generic cluster names
- **Report security issues** privately via email (not public issues)

## 📋 Pull Request Process

1. **Update documentation** if you change functionality
2. **Add examples** for new features
3. **Keep PRs focused** - one feature/fix per PR
4. **Write clear PR descriptions**:
   - What problem does this solve?
   - How does it solve it?
   - Any breaking changes?
   - Testing performed?

## 🎨 Commit Message Format

Use conventional commits:

```
type(scope): brief description

Longer description if needed

Fixes #123
```

**Types**:

- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `refactor`: Code refactoring
- `test`: Adding tests
- `chore`: Maintenance tasks

**Examples**:

```
feat(migration): add parallel processing support
fix(cleanup): handle orphaned ApplicationSets correctly
docs(readme): add troubleshooting section
```

## 🤔 Questions?

- **General questions**: Open a [GitHub Discussion](https://github.com/seansilvestri/argocd-migration-toolkit/discussions)
- **Bug reports**: Open a [GitHub Issue](https://github.com/seansilvestri/argocd-migration-toolkit/issues)
- **Security concerns**: Email directly (see README)

## 📜 Code of Conduct

- Be respectful and inclusive
- Welcome newcomers
- Focus on constructive feedback
- Assume good intentions

## 🙏 Recognition

Contributors will be recognized in:

- README.md acknowledgments section
- Release notes
- Project documentation

Thank you for helping make ArgoCD migrations safer for everyone! 🚀
