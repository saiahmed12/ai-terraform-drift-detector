import json
import sys

def insert_into_json(main_json, insert_obj, insertion_key):
    if insertion_key in main_json:
        main_json[insertion_key].append(insert_obj)
    else:
        for key, value in main_json.items():
            if isinstance(value, dict):
                insert_into_json(value, insert_obj, insertion_key)

def main():
    if len(sys.argv) != 4:
        print("Usage: python insert_big_json.py main_file insert_file insertion_key")
        sys.exit(1)

    main_file_path = sys.argv[1]
    insert_file_path = sys.argv[2]
    insertion_key = sys.argv[3]

    with open(main_file_path, 'r') as main_file:
        main_json = json.load(main_file)

    with open(insert_file_path, 'r') as insert_file:
        insert_json_data = json.load(insert_file)

    insert_into_json(main_json, insert_json_data, insertion_key)

    print(json.dumps(main_json, indent=2))

if __name__ == "__main__":
    main()