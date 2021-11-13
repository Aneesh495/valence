// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title RedBlackTree
/// @notice Storage-based self-balancing Red-Black binary search tree for sorted price levels.
/// @dev Enables O(log N) insertion, removal, and predecessor/successor traversal on-chain.
library RedBlackTree {
    uint256 internal constant EMPTY = 0;

    struct Node {
        uint256 parent;
        uint256 left;
        uint256 right;
        bool red;
    }

    struct Tree {
        uint256 root;
        uint256 count;
        mapping(uint256 => Node) nodes;
    }

    error RedBlackTree__KeyAlreadyExists();
    error RedBlackTree__KeyNotFound();
    error RedBlackTree__ZeroKeyNotAllowed();

    /// @notice Returns true if the tree has no nodes.
    function isEmpty(Tree storage self) internal view returns (bool) {
        return self.root == EMPTY;
    }

    /// @notice Checks if a key exists in the tree.
    function exists(Tree storage self, uint256 key) internal view returns (bool) {
        if (key == EMPTY) return false;
        if (self.root == key) return true;
        if (self.nodes[key].parent != EMPTY) return true;
        return false;
    }

    /// @notice Returns the minimum key in the tree.
    function first(Tree storage self) internal view returns (uint256) {
        uint256 current = self.root;
        if (current == EMPTY) return EMPTY;
        while (self.nodes[current].left != EMPTY) {
            current = self.nodes[current].left;
        }
        return current;
    }

    /// @notice Returns the maximum key in the tree.
    function last(Tree storage self) internal view returns (uint256) {
        uint256 current = self.root;
        if (current == EMPTY) return EMPTY;
        while (self.nodes[current].right != EMPTY) {
            current = self.nodes[current].right;
        }
        return current;
    }

    /// @notice Returns the in-order successor of key.
    function next(Tree storage self, uint256 key) internal view returns (uint256) {
        if (key == EMPTY) return EMPTY;
        if (self.nodes[key].right != EMPTY) {
            uint256 current = self.nodes[key].right;
            while (self.nodes[current].left != EMPTY) {
                current = self.nodes[current].left;
            }
            return current;
        }
        uint256 p = self.nodes[key].parent;
        uint256 child = key;
        while (p != EMPTY && child == self.nodes[p].right) {
            child = p;
            p = self.nodes[p].parent;
        }
        return p;
    }

    /// @notice Returns the in-order predecessor of key.
    function prev(Tree storage self, uint256 key) internal view returns (uint256) {
        if (key == EMPTY) return EMPTY;
        if (self.nodes[key].left != EMPTY) {
            uint256 current = self.nodes[key].left;
            while (self.nodes[current].right != EMPTY) {
                current = self.nodes[current].right;
            }
            return current;
        }
        uint256 p = self.nodes[key].parent;
        uint256 child = key;
        while (p != EMPTY && child == self.nodes[p].left) {
            child = p;
            p = self.nodes[p].parent;
        }
        return p;
    }

    /// @notice Inserts a non-zero key into the Red-Black tree.
    function insert(Tree storage self, uint256 key) internal {
        if (key == EMPTY) revert RedBlackTree__ZeroKeyNotAllowed();
        if (exists(self, key)) revert RedBlackTree__KeyAlreadyExists();

        uint256 cursor = self.root;
        uint256 parent = EMPTY;

        while (cursor != EMPTY) {
            parent = cursor;
            if (key < cursor) {
                cursor = self.nodes[cursor].left;
            } else {
                cursor = self.nodes[cursor].right;
            }
        }

        self.nodes[key] = Node({
            parent: parent,
            left: EMPTY,
            right: EMPTY,
            red: true
        });

        if (parent == EMPTY) {
            self.root = key;
        } else if (key < parent) {
            self.nodes[parent].left = key;
        } else {
            self.nodes[parent].right = key;
        }

        self.count++;
        insertFixup(self, key);
    }

    /// @notice Removes a key from the Red-Black tree.
    function remove(Tree storage self, uint256 key) internal {
        if (!exists(self, key)) revert RedBlackTree__KeyNotFound();

        uint256 y = key;
        uint256 x;
        uint256 xParent;
        bool yOriginalColor = self.nodes[y].red;

        if (self.nodes[key].left == EMPTY) {
            x = self.nodes[key].right;
            xParent = self.nodes[key].parent;
            rbTransplant(self, key, self.nodes[key].right);
        } else if (self.nodes[key].right == EMPTY) {
            x = self.nodes[key].left;
            xParent = self.nodes[key].parent;
            rbTransplant(self, key, self.nodes[key].left);
        } else {
            y = self.nodes[key].right;
            while (self.nodes[y].left != EMPTY) {
                y = self.nodes[y].left;
            }
            yOriginalColor = self.nodes[y].red;
            x = self.nodes[y].right;
            if (self.nodes[y].parent == key) {
                xParent = y;
            } else {
                xParent = self.nodes[y].parent;
                rbTransplant(self, y, self.nodes[y].right);
                self.nodes[y].right = self.nodes[key].right;
                self.nodes[self.nodes[y].right].parent = y;
            }
            rbTransplant(self, key, y);
            self.nodes[y].left = self.nodes[key].left;
            self.nodes[self.nodes[y].left].parent = y;
            self.nodes[y].red = self.nodes[key].red;
        }

        delete self.nodes[key];
        self.count--;

        if (!yOriginalColor) {
            removeFixup(self, x, xParent);
        }
    }

    // --- Internal Tree Balancing Rotations ---

    function rotateLeft(Tree storage self, uint256 x) private {
        uint256 y = self.nodes[x].right;
        self.nodes[x].right = self.nodes[y].left;
        if (self.nodes[y].left != EMPTY) {
            self.nodes[self.nodes[y].left].parent = x;
        }
        self.nodes[y].parent = self.nodes[x].parent;
        if (self.nodes[x].parent == EMPTY) {
            self.root = y;
        } else if (x == self.nodes[self.nodes[x].parent].left) {
            self.nodes[self.nodes[x].parent].left = y;
        } else {
            self.nodes[self.nodes[x].parent].right = y;
        }
        self.nodes[y].left = x;
        self.nodes[x].parent = y;
    }

    function rotateRight(Tree storage self, uint256 y) private {
        uint256 x = self.nodes[y].left;
        self.nodes[y].left = self.nodes[x].right;
        if (self.nodes[x].right != EMPTY) {
            self.nodes[self.nodes[x].right].parent = y;
        }
        self.nodes[x].parent = self.nodes[y].parent;
        if (self.nodes[y].parent == EMPTY) {
            self.root = x;
        } else if (y == self.nodes[self.nodes[y].parent].right) {
            self.nodes[self.nodes[y].parent].right = x;
        } else {
            self.nodes[self.nodes[y].parent].left = x;
        }
        self.nodes[x].right = y;
        self.nodes[y].parent = x;
    }

    function insertFixup(Tree storage self, uint256 z) private {
        while (z != self.root && self.nodes[self.nodes[z].parent].red) {
            uint256 parent = self.nodes[z].parent;
            uint256 grandParent = self.nodes[parent].parent;

            if (parent == self.nodes[grandParent].left) {
                uint256 y = self.nodes[grandParent].right;
                if (y != EMPTY && self.nodes[y].red) {
                    self.nodes[parent].red = false;
                    self.nodes[y].red = false;
                    self.nodes[grandParent].red = true;
                    z = grandParent;
                } else {
                    if (z == self.nodes[parent].right) {
                        z = parent;
                        rotateLeft(self, z);
                        parent = self.nodes[z].parent;
                        grandParent = self.nodes[parent].parent;
                    }
                    self.nodes[parent].red = false;
                    self.nodes[grandParent].red = true;
                    rotateRight(self, grandParent);
                }
            } else {
                uint256 y = self.nodes[grandParent].left;
                if (y != EMPTY && self.nodes[y].red) {
                    self.nodes[parent].red = false;
                    self.nodes[y].red = false;
                    self.nodes[grandParent].red = true;
                    z = grandParent;
                } else {
                    if (z == self.nodes[parent].left) {
                        z = parent;
                        rotateRight(self, z);
                        parent = self.nodes[z].parent;
                        grandParent = self.nodes[parent].parent;
                    }
                    self.nodes[parent].red = false;
                    self.nodes[grandParent].red = true;
                    rotateLeft(self, grandParent);
                }
            }
        }
        self.nodes[self.root].red = false;
    }

    function removeFixup(Tree storage self, uint256 x, uint256 xParent) private {
        while (x != self.root && (x == EMPTY || !self.nodes[x].red)) {
            if (x == self.nodes[xParent].left) {
                uint256 w = self.nodes[xParent].right;
                if (self.nodes[w].red) {
                    self.nodes[w].red = false;
                    self.nodes[xParent].red = true;
                    rotateLeft(self, xParent);
                    w = self.nodes[xParent].right;
                }
                if (
                    (self.nodes[w].left == EMPTY || !self.nodes[self.nodes[w].left].red) &&
                    (self.nodes[w].right == EMPTY || !self.nodes[self.nodes[w].right].red)
                ) {
                    self.nodes[w].red = true;
                    x = xParent;
                    xParent = self.nodes[x].parent;
                } else {
                    if (self.nodes[w].right == EMPTY || !self.nodes[self.nodes[w].right].red) {
                        if (self.nodes[w].left != EMPTY) {
                            self.nodes[self.nodes[w].left].red = false;
                        }
                        self.nodes[w].red = true;
                        rotateRight(self, w);
                        w = self.nodes[xParent].right;
                    }
                    self.nodes[w].red = self.nodes[xParent].red;
                    self.nodes[xParent].red = false;
                    if (self.nodes[w].right != EMPTY) {
                        self.nodes[self.nodes[w].right].red = false;
                    }
                    rotateLeft(self, xParent);
                    x = self.root;
                    break;
                }
            } else {
                uint256 w = self.nodes[xParent].left;
                if (self.nodes[w].red) {
                    self.nodes[w].red = false;
                    self.nodes[xParent].red = true;
                    rotateRight(self, xParent);
                    w = self.nodes[xParent].left;
                }
                if (
                    (self.nodes[w].right == EMPTY || !self.nodes[self.nodes[w].right].red) &&
                    (self.nodes[w].left == EMPTY || !self.nodes[self.nodes[w].left].red)
                ) {
                    self.nodes[w].red = true;
                    x = xParent;
                    xParent = self.nodes[x].parent;
                } else {
                    if (self.nodes[w].left == EMPTY || !self.nodes[self.nodes[w].left].red) {
                        if (self.nodes[w].right != EMPTY) {
                            self.nodes[self.nodes[w].right].red = false;
                        }
                        self.nodes[w].red = true;
                        rotateLeft(self, w);
                        w = self.nodes[xParent].left;
                    }
                    self.nodes[w].red = self.nodes[xParent].red;
                    self.nodes[xParent].red = false;
                    if (self.nodes[w].left != EMPTY) {
                        self.nodes[self.nodes[w].left].red = false;
                    }
                    rotateRight(self, xParent);
                    x = self.root;
                    break;
                }
            }
        }
        if (x != EMPTY) {
            self.nodes[x].red = false;
        }
    }

    function rbTransplant(Tree storage self, uint256 u, uint256 v) private {
        if (self.nodes[u].parent == EMPTY) {
            self.root = v;
        } else if (u == self.nodes[self.nodes[u].parent].left) {
            self.nodes[self.nodes[u].parent].left = v;
        } else {
            self.nodes[self.nodes[u].parent].right = v;
        }
        if (v != EMPTY) {
            self.nodes[v].parent = self.nodes[u].parent;
        }
    }
}
