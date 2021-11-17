// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title LinkedList
/// @notice Storage-based doubly-linked list for FIFO execution queues at order book price levels.
/// @dev Enables O(1) appending to tail, O(1) popping from head, and O(1) deletion by element ID.
library LinkedList {
    bytes32 internal constant SENTINEL = bytes32(0);

    struct Element {
        bytes32 prev;
        bytes32 next;
        bool exists;
    }

    struct List {
        bytes32 head;
        bytes32 tail;
        uint256 size;
        mapping(bytes32 => Element) elements;
    }

    error LinkedList__AlreadyExists();
    error LinkedList__DoesNotExist();
    error LinkedList__ListIsEmpty();
    error LinkedList__ZeroIdNotAllowed();

    /// @notice Returns true if the list contains zero elements.
    function isEmpty(List storage self) internal view returns (bool) {
        return self.size == 0;
    }

    /// @notice Returns true if the element exists in the list.
    function contains(List storage self, bytes32 id) internal view returns (bool) {
        return self.elements[id].exists;
    }

    /// @notice Appends an element to the tail of the list.
    function pushBack(List storage self, bytes32 id) internal {
        if (id == SENTINEL) revert LinkedList__ZeroIdNotAllowed();
        if (self.elements[id].exists) revert LinkedList__AlreadyExists();

        self.elements[id] = Element({
            prev: self.tail,
            next: SENTINEL,
            exists: true
        });

        if (self.tail != SENTINEL) {
            self.elements[self.tail].next = id;
        } else {
            self.head = id;
        }

        self.tail = id;
        self.size++;
    }

    /// @notice Removes and returns the element at the head of the list.
    function popFront(List storage self) internal returns (bytes32 front) {
        if (self.size == 0) revert LinkedList__ListIsEmpty();
        front = self.head;
        remove(self, front);
    }

    /// @notice Removes an arbitrary element from the list in O(1).
    function remove(List storage self, bytes32 id) internal {
        if (!self.elements[id].exists) revert LinkedList__DoesNotExist();

        bytes32 prevId = self.elements[id].prev;
        bytes32 nextId = self.elements[id].next;

        if (prevId != SENTINEL) {
            self.elements[prevId].next = nextId;
        } else {
            self.head = nextId;
        }

        if (nextId != SENTINEL) {
            self.elements[nextId].prev = prevId;
        } else {
            self.tail = prevId;
        }

        delete self.elements[id];
        self.size--;
    }
}
