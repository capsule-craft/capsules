module sui_utils::vec_map2 {
    use std::string::{String as UTF8, utf8};
    use std::vector;
    use sui::vec_map::{Self, VecMap};

    // This will fail if there is an odd number of entries in the first vector
    // It will also fail if the bytes are not utf8 strings
    public fun to_string_string_vec_map(bytes: &vector<vector<u8>>): VecMap<UTF8, UTF8> {
        let output = vec_map::empty<UTF8, UTF8>();
        let i = 0;

        while (i < vector::length(bytes)) {
            let key = utf8(*vector::borrow(bytes, i));
            let value = utf8(*vector::borrow(bytes, i + 1));

            vec_map::insert(&mut output, key, value);

            i = i + 2;
        };

        output
    }

    public fun set<K: copy, drop, V: drop>(self: &mut VecMap<K, V>, key: K, value: V) {
        if (vec_map::contains(self, key)) {
            vec_map::remove(self, key);
        };
        vec_map::insert(self, key, value);
    }
}