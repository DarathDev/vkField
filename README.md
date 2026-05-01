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

## Citations

The algorithm used in the simulator is based on this work:

```
J. A. Jensen and N. B. Svendsen, "Calculation of pressure fields from arbitrarily shaped, apodized, and excited ultrasound transducers," in IEEE Transactions on Ultrasonics, Ferroelectrics, and Frequency Control, vol. 39, no. 2, pp. 262-267, March 1992, doi: 10.1109/58.139123.
```

See the following for background knowledge on creating a linear model of ultrasound

```
J.A. Jensen: Linear description of ultrasound imaging systems, Notes for the International Summer School on Advanced Ultrasound Imaging, Technical University of Denmark July 5 to July 9, 1999, Technical University of Denmark, June, 1999.
```

And finally a special thanks to [Field II](https://field-ii.dk) for establishing a gold standard for ultrasound simulation.
