module sui_utils::vector2 {
    use std::vector;
    
    const EINVALID_SLICE: u64 = 0;

    // Takes a slice of a vector from the start-index up to, but not including, the end-index.
    // Does not modify the original vector
    public fun slice<T: store + copy>(vec: &vector<T>, start: u64, end: u64): vector<T> {
        assert!(end >= start, EINVALID_SLICE);

        let (i, slice) = (start, vector::empty<T>());
        while (i < end) {
            vector::push_back(&mut slice, *vector::borrow(vec, i));
            i = i + 1;
        };

        slice
    }

    // O(n) operation. Preserves order of vector. Removes and returns the segment of the vector
    // corresponding to [start, end) (the end-index is not included).
    public fun slice_mut<T: store>(vec: &mut vector<T>, start: u64, end: u64): vector<T> {
        assert!(end >= start, EINVALID_SLICE);

        let (i, slice) = (start, vector::empty<T>());
        while (i < end) {
            vector::push_back(&mut slice, vector::swap_remove(vec, i));
            i = i + 1;
        };

        // Continue to reverse the non-sliced elements
        let j = vector::length(vec) - 1;
        while (i < j) {
            vector::swap(vec, i, j);
            i = i + 1;
            j = j - 1;
        };

        // Now put the original vector back in order
        let (i, len, remainder) = (0, vector::length(vec), vector::empty<T>());
        while (i < (len - start)) {
            vector::push_back(&mut remainder, vector::pop_back(vec));
            i = i + 1;
        };
        vector::append(vec, remainder);

        slice
    }
}