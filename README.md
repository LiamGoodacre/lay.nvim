# lay.nvim

Layout a subset of your windows by editing a layout expression.

For example if you have a layout such as:

```
    +---------+---------+
    |         |         |
    |         |    2    |
    |         |         |
    |    1    +---------+
    |         |         |
    |         |    3    |
    |         |         |
    +---------+---------+
```

This would be captured by the expression `h{1, v{2, 3}}`.

If you then edited this to be `v{h{1, 2}, 3}`, you'd end up with:

```
    +---------+---------+
    |         |         |
    |    1    |    2    |
    |         |         |
    +---------+---------+
    |                   |
    |         3         |
    |                   |
    +-------------------+
```

See `:help lay.nvim` / [docs](./doc/lay.nvim.txt) for details.

