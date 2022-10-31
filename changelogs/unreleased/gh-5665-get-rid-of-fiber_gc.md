## bugfix/core

* **[Breaking change]** box\_region allocations not paired with
box\_region\_truncate will produce leaks. Previously one can
rely on some API (like executing a DML statement) truncating fiber
region to 0. Now API stop truncating memory it does not own.
