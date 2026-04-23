# VkField

This is a GPU accelerated implementation of [Field II](field-ii.dk) using Vulkan.

While it can perform simulations for arbitrary sets of rectangular and triangular elements, the current front end only has functions for easy simulations of row column arrays.

## Building the Library

```shell
odin run . -debug -- -lib -debug -matlab
```

Note: MATLAB will crash if a debug trap is hit and no debugger is attached.

## Testing

```shell
odin run . -debug -- -test -debug
./bin/release/vkField_tests
```
