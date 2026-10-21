"""Application entry point."""

from project_name.utils.name import add


def main() -> None:
    """
    Main function to demonstrate the add function.
    """
    result = add(2, 3)
    print(f"2 + 3 = {result}")


if __name__ == "__main__":
    main()
