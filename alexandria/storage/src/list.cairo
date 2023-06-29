use hash::LegacyHash;
use integer::U32DivRem;
use option::OptionTrait;
use starknet::{storage_read_syscall, storage_write_syscall, SyscallResult, SyscallResultTrait};
use starknet::storage_access::{StorageAccess, StorageBaseAddress, storage_address_to_felt252, storage_address_from_base, storage_address_from_base_and_offset, storage_base_address_from_felt252};
use traits::{Default, DivRem, IndexView, Into, TryInto};

const POW2_8: u32 = 256; // 2^8

#[derive(Drop)]
struct List<T> {
    address_domain: u32,
    base: StorageBaseAddress,
    len: u32, // number of elements in array
    storage_size: u8
}

trait ListTrait<T> {
    fn len(self: @List<T>) -> u32;
    fn is_empty(self: @List<T>) -> bool;
    fn append(ref self: List<T>, value: T) -> u32;
    fn get(self: @List<T>, index: u32) -> T;
    fn set(ref self: List<T>, index: u32, value: T);
}

// when writing elements in storage, we need to know how many storage slots
// they take up to properly calculate the offset into a storage segment
// that's what this trait provides
// it's very similar to the `size_internal` function in StorageAccess trait
// with one crutial difference - this function does not need a T element
// to return the size of the T element!
trait StorageSize<T> {
    fn storage_size() -> u8;
}

// any type that can Into to u128 has a size of 1
impl StorageSizeU128<T, impl TInto: Into<T, u128>> of StorageSize<T> {
    fn storage_size() -> u8 {
        1
    }
}

// any type that can Into to felt252 has a size of 1
impl StorageSizeFelt252<T, impl TInto: Into<T, felt252>> of StorageSize<T> {
    fn storage_size() -> u8 {
        1
    }
}

// any type that can Into to u258 has a size of 2
impl StorageSizeU256<T, impl TInto: Into<T, u256>> of StorageSize<T> {
    fn storage_size() -> u8 {
        2
    }
}

impl ListImpl<T,
    impl TCopy: Copy<T>,
    impl TDrop: Drop<T>,
    impl TStorageAccess: StorageAccess<T>,
    impl TStorageSize: StorageSize<T>>
    of ListTrait<T>
{
    fn len(self: @List<T>) -> u32 {
        *self.len
    }

    fn is_empty(self: @List<T>) -> bool {
        *self.len == 0
    }

    fn append(ref self: List<T>, value: T) -> u32 {
        let (base, offset) = calculate_base_and_offset_for_index(self.base, self.len, self.storage_size);
        StorageAccess::write_at_offset_internal(
            self.address_domain,
            base,
            offset,
            value
        ).unwrap_syscall();

        let append_at = self.len;
        self.len += 1;
        StorageAccess::write(self.address_domain, self.base, self.len);

        append_at
    }

    fn get(self: @List<T>, index: u32) -> T {
        assert(index < *self.len, 'index out of bounds');
        let (base, offset) = calculate_base_and_offset_for_index(*self.base, index, *self.storage_size);
        StorageAccess::read_at_offset_internal(
            *self.address_domain,
            base,
            offset
        ).unwrap_syscall()
    }

    fn set(ref self: List<T>, index: u32, value: T) {
        assert(index < self.len, 'index out of bounds');
        let (base, offset) = calculate_base_and_offset_for_index(self.base, index, self.storage_size);
        StorageAccess::write_at_offset_internal(
            self.address_domain,
            base,
            offset,
            value
        ).unwrap_syscall();
    }
}

impl AListIndexViewImpl<T,
    impl TCopy: Copy<T>,
    impl TDrop: Drop<T>,
    impl TStorageAccess: StorageAccess<T>,
    impl TStorageSize: StorageSize<T>>
    of IndexView<List<T>, u32, T>
{
    fn index(self: @List<T>, index: u32) -> T {
        self.get(index)
    }
}

// this functions finds the StorageBaseAddress of a "storage segment" (a continuous space of 256 storage slots)
// and an offset into that segment where a value at `index` is stored
// each segment can hold up to `256 // storage_size` elements
//
// the way how the address is calculated is very similar to how a LegacyHash map works:
//
// first we take the `list_base` address which is derived from the name of the storage variable
// then we hash it with a `key` which is the number of the segment where the element at `index` belongs (from 0 upwards)
// we hash these two values: H(list_base, key) to the the `segment_base` address
// finally, we calculate the offset into this segment, taking into account the size of the elements held in the array
//
// by way of example:
//
// say we have an List<Foo> and Foo's storage_size is 8
// struct storage: {
//    bar: List<Foo>
// }
//
// the storage layout would look like this:
//
// segment0: [0..31] - elements at indexes 0 to 31
// segment1: [32..63] - elements at indexes 32 to 63
// segment2: [64..95] - elements at indexes 64 to 95
// etc.
//
// where addresses of each segment are:
//
// segment0 = hash(bar.address(), 0)
// segment1 = hash(bar.address(), 1)
// segment2 = hash(bar.address(), 2)
//
// so for getting a Foo at index 90 this function would return address of segment2 and offset of 26

fn calculate_base_and_offset_for_index(list_base: StorageBaseAddress, index: u32, storage_size: u8) -> (StorageBaseAddress, u8) {
    let max_elements = POW2_8 / storage_size.into();
    let (key, offset) = U32DivRem::div_rem(index, max_elements.try_into().unwrap());

    let segment_base = storage_base_address_from_felt252(
        LegacyHash::hash(
            storage_address_to_felt252(
                storage_address_from_base(
                    list_base
                )
            ),
            key
    ));

    (segment_base, offset.try_into().unwrap() * storage_size)
}

impl ListStorageAccess<T, impl TStorageSize: StorageSize<T>> of StorageAccess<List<T>> {
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult<List<T>> {
        let len: u32 = StorageAccess::read(address_domain, base).unwrap_syscall();
        let storage_size: u8 = StorageSize::<T>::storage_size();
        Result::Ok(List { address_domain, base, len, storage_size })
    }

    fn write(address_domain: u32, base: StorageBaseAddress, value: List<T>) -> SyscallResult<()> {
        StorageAccess::write(address_domain, base, value.len)
    }

    fn read_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8
    ) -> SyscallResult<List<T>> {
        let len: u32 = StorageAccess::read_at_offset_internal(address_domain, base, offset).unwrap_syscall();
        let storage_size: u8 = StorageSize::<T>::storage_size();
        Result::Ok(List { address_domain, base, len, storage_size })
    }

    fn write_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8, value: List<T>
    ) -> SyscallResult<()> {
        StorageAccess::write_at_offset_internal(address_domain, base, offset, value.len)
    }

    fn size_internal(value: List<T>) -> u8 {
        StorageAccess::size_internal(value.len)
    }
}
