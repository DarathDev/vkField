# VkField

This is a GPU accelerated implementation of [Field II](https://field-ii.dk) using Vulkan.

While it can perform simulations for arbitrary sets of rectangular and triangular elements, the current front end only has functions for easy simulations of row column arrays.

## Requirements

- [Odin](https://github.com/odin-lang/Odin)
- [Slang](https://github.com/shader-slang/slang)

### Optional

- [MATLAB](https://www.mathworks.com/products/matlab.html)

## Building the Library

```shell
odin run . -- -lib -matlab
```

Note: MATLAB will crash if a debug trap is hit and no debugger is attached.

## Testing

```shell
odin run . -- -test
./bin/release/vkField_tests
```
