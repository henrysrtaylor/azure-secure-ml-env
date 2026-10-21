# py-project-starter

A modern Python starter template for new projects and experiments. It includes uv dependency management, Ruff linting and formatting, pytest with coverage, and GitHub Actions continuous integration.

## 📋 Core Components

- `pyproject.toml`: Project metadata, dependencies, supported Python version, build configuration, and settings for Ruff and pytest.
- uv: The project and dependency manager. It creates the local environment, installs dependencies, and runs project tools.
- Ruff: A fast Python linter and formatter. It identifies code-quality issues, can automatically fix many of them, and verifies consistent code formatting.
- GitHub Actions: The workflow in `.github/workflows/ci.yml` runs automated checks on pushes and pull requests.
- `.venv`: The local virtual environment created by `uv sync`. Do not commit it to Git.
- `uv.lock`: The dependency lock file that records exact package versions. Commit it to Git so development and CI use the same dependencies.

## 📈 Future Roadmap

- Placeholder for template

## 📂 Project Structure

```text
py-project-starter/
├── .github/
│   └── workflows/
│       └── ci.yml          # Continuous integration workflow
├── project_name/           # Application package
│   ├── utils/              # Reusable helper modules
│   ├── __init__.py         # Public package interface
│   └── main.py             # Application entry point
├── tests/                  # Test suite
├── docs/                   # Documentation
├── .env.example            # Environment variable template
├── .gitignore              # Git ignore rules
├── pyproject.toml          # Project and tool configuration
├── README.md               # Project documentation
└── uv.lock                 # Locked dependency versions
```

## 🚀 Getting Started

### Prerequisites

You need:

- Python 3.12 or later
- Git
- [uv](https://docs.astral.sh/uv/)

Install uv on Windows:

```powershell
powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
```

Install uv on Linux or macOS:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

### Clone the Repository

```powershell
git clone <your-repo-url>
cd <repo-folder>
```

### Install Dependencies

From the project root, create or update the local virtual environment and
install the project dependencies:

```powershell
uv sync
```

## 🛠️ Development

Run the configured checks with:

```powershell
uv run ruff check .
uv run ruff format --check .
uv run pytest
```

## 🤝 Contributing

Contributions are welcome! As the project is still in early development, please open an issue before starting substantial work so that proposed changes can be discussed and coordinated.

To contribute:

1. Fork the repository.
2. Create a branch for your change.
3. Install the development dependencies with `uv sync`.
4. Run the linting and test checks.
5. Submit a pull request describing your changes.

Bug reports, feature suggestions, documentation improvements, and new agent ideas are all welcome.
