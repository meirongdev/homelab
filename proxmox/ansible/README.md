## Prerequisites

- Ansible installed on your control node.
    ```bash
    brew install ansible
    ```
- SSH access to all managed nodes.
    ```bash
    ssh-copy-id -i public_key_file user@managed_node_ip
    ssh-add private_key_file
    ```
    - `ssh-add` will cache your private key for the duration of your session, so you don't have to enter the passphrase multiple times. Or else you should specify the `key file` in your command with `-i` option, `ssh -i private_key user@managed_node_ip`.
- Python installed on all managed nodes.

- [Just](https://github.com/casey/just)
    ```bash
    brew install just
    ```

Just is very similar to `Makefile`, but with better syntax highlighting and easier to use.

## Tasks

### Download Ubuntu Cloud Image for Proxmox

```bash
just download-cloud-image
```

