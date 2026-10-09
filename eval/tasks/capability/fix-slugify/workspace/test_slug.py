from slug import slugify


def test_punctuation():
    assert slugify("Hello, World!") == "hello-world"


def test_spaces():
    assert slugify("  Many   spaces  ") == "many-spaces"
