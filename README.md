<!-- This should be the location of the title of the repository, normally the short name -->
# Turbonomic Container Platform

A helm repo and store of yaml files required for customer initiated deployment of Turbonomic agents kubeturbo prometurbo in customer owned container platform clusters

## Usage

For the helm repo instructions visit https://ibm.github.io/turbonomic-container-platform/

```bash
helm repo add turbo-charts https://ibm.github.io/turbonomic-container-platform/
```

For deployment via operator or yamls use the folder [deploy](./deploy/)

<!-- A notes section is useful for anything that isn't covered in the Usage or Scope. Like what we have below. -->
## Notes

<!-- Questions can be useful but optional, this gives you a place to say, "This is how to contact this project maintainers or create PRs -->
If you have any questions or issues you can create a new [issue here][issues].

Pull requests are very welcome! Make sure your patches are well tested.
Ideally create a topic branch for every separate change you make. For
example:

1. Fork the repo
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Added some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

## License

```text
#
# Copyright IBM Corp. 2024
# SPDX-License-Identifier: Apache-2.0
#
```

## Authors
