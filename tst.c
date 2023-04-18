#include <stddef.h>
#include <assert.h>
#include <stdlib.h>
#include <string.h>

struct space {
	char *name;
	int index_id_max;
};

struct space_read_view {
	char *name;
	int *index_map;
};

static void *
alloc_self(char **buf, ptrdiff_t *buf_size, size_t self_size)
{
	*buf_size -= self_size;
	if (*buf_size >= 0) {
		char *tmp = *buf;
		*buf += self_size;
		return tmp;
	}
	return *buf;
}

static void
alloc_data(char **buf, ptrdiff_t *buf_size, void *member, size_t data_size)
{
	*buf_size -= data_size;
	if (*buf_size >= 0) {
		*(char **)member = *buf;
		*buf += data_size;
	}
}

static void
alloc_str(char **buf, ptrdiff_t *buf_size, void *member, size_t str_size)
{
	*buf_size -= str_size;
	if (*buf_size >= 0)
		*(char **)member = *buf + *buf_size;
}

struct space_read_view *
read_view_alloc(char *buf, ptrdiff_t *size, struct space *space)
{
	struct space_read_view *view;
	view = alloc_self(&buf, size, sizeof(*view));
	alloc_data(&buf, size, &view->index_map,
		   sizeof(*view->index_map) * (space->index_id_max + 1));
	alloc_str(&buf, size, &view->name, strlen(space->name) + 1);
	return view;
}

int
main(void)
{
	struct space space;
	space.name = "foo";
	space.index_id_max = 7;

	ptrdiff_t save = 0;
	ptrdiff_t size = 0;
	struct space_read_view *view;

	read_view_alloc(NULL, &size, &space);
	size = -size;
	save = size;
	char *buf = malloc(size);
	view = read_view_alloc(buf, &size, &space);
	assert(size == 0);

	assert(buf == (char *)view);
	assert((char *)view->index_map == buf + sizeof(*view));
	assert(view->name == (char *)view->index_map +
			      sizeof(int) * (space.index_id_max + 1));
	assert((char *)view->name + strlen(space.name) + 1 - (char *)view == save);

	return 0;
}
