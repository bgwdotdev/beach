# Beach Examples

For each example, you have its respective [module name](https://tour.gleam.run/basics/modules/).
You can find the source associated to the example under `./src/$MODULE_NAME`.

To run the examples, must first create an ssh host key pair for your application:

```sh
# this is only needed once
ssh-keygen -t ed25519 -f ssh_host_ed25519_key
```

after which can run the following:

```sh
# replace $MODULE_NAME with the name of the module associated to each example
gleam run -m $MODULE_NAME/app
```

## Examples

Here is a list of all the examples and their associated module name (formatted
"`$MODULE_NAME` - Example title"):

- [`counter` - Simple Counter](./src/counter)
- [`chat` - Basic Multiuser Chat](./src/chat)
