# Contributing to OpenLiteSpeed Optimizer

First off, thank you for considering contributing to this project! 🎉

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check the existing issues to avoid duplicates. When you create a bug report, include as many details as possible:

- **Use a clear and descriptive title**
- **Describe the exact steps to reproduce the problem**
- **Provide specific examples** (config snippets, log outputs)
- **Describe the behavior you observed** and what you expected
- **Include system information**: Ubuntu version, OpenLiteSpeed version, RAM, etc.

### Suggesting Enhancements

Enhancement suggestions are tracked as GitHub issues. When creating an enhancement suggestion:

- **Use a clear and descriptive title**
- **Provide a detailed description** of the proposed enhancement
- **Explain why this enhancement would be useful**
- **List any potential drawbacks or complications**

### Pull Requests

1. **Fork the repository** and create your branch from `main`
2. **Test your changes thoroughly** on a test system first
3. **Ensure scripts follow the existing code style**:
   - Use `set -euo pipefail` at the top
   - Include clear comments
   - Follow existing naming conventions
   - Add logging for important operations
4. **Update documentation** if you change functionality
5. **Write a clear commit message** describing your changes
6. **Submit a pull request** with a clear description

### Code Style Guidelines

- **Bash scripts**:
  - Use 2 spaces for indentation
  - Use `_variable` for local variables
  - Use `CONSTANT` for constants
  - Always quote variables: `"$variable"`
  - Use `$(command)` instead of backticks
  - Include error handling

- **Comments**:
  - Add comments for complex logic
  - Use `#` for single-line comments
  - Use multi-line blocks for function descriptions

### Testing Checklist

Before submitting, ensure:

- [ ] Scripts run without errors on Ubuntu 20.04+
- [ ] All functions handle errors gracefully
- [ ] Backup/rollback mechanisms work correctly
- [ ] Lock files prevent concurrent execution
- [ ] Logging is clear and helpful
- [ ] MD5 checks prevent unnecessary restarts
- [ ] Config validation works before restart

### Commit Message Guidelines

Format: `type: brief description`

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting)
- `refactor`: Code refactoring
- `test`: Adding tests
- `chore`: Maintenance tasks

Examples:
```
feat: add support for HTTP/3 configuration
fix: prevent race condition in freeze script
docs: update installation instructions
```

## Questions?

Feel free to open an issue with your question or reach out via GitHub discussions.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
