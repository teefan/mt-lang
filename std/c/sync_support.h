#ifndef MT_SYNC_SUPPORT_H
#define MT_SYNC_SUPPORT_H

#include <stdlib.h>
#include <uv.h>

typedef struct mt_mutex {
  uv_mutex_t native;
} mt_mutex;

typedef struct mt_condition {
  uv_cond_t native;
} mt_condition;

typedef struct mt_semaphore {
  uv_sem_t native;
} mt_semaphore;

static inline int mt_mutex_create(mt_mutex** out_mutex) {
  if (out_mutex != NULL) {
    *out_mutex = NULL;
  }

  mt_mutex* mutex = (mt_mutex*) malloc(sizeof(mt_mutex));
  if (mutex == NULL) {
    return UV_ENOMEM;
  }

  int status = uv_mutex_init(&mutex->native);
  if (status != 0) {
    free(mutex);
    return status;
  }

  if (out_mutex != NULL) {
    *out_mutex = mutex;
  }
  return 0;
}

static inline int mt_mutex_create_recursive(mt_mutex** out_mutex) {
  if (out_mutex != NULL) {
    *out_mutex = NULL;
  }

  mt_mutex* mutex = (mt_mutex*) malloc(sizeof(mt_mutex));
  if (mutex == NULL) {
    return UV_ENOMEM;
  }

  int status = uv_mutex_init_recursive(&mutex->native);
  if (status != 0) {
    free(mutex);
    return status;
  }

  if (out_mutex != NULL) {
    *out_mutex = mutex;
  }
  return 0;
}

static inline void mt_mutex_destroy(mt_mutex* handle) {
  if (handle == NULL) {
    return;
  }

  uv_mutex_destroy(&handle->native);
  free(handle);
}

static inline void mt_mutex_lock(mt_mutex* handle) {
  uv_mutex_lock(&handle->native);
}

static inline int mt_mutex_try_lock(mt_mutex* handle) {
  return uv_mutex_trylock(&handle->native);
}

static inline void mt_mutex_unlock(mt_mutex* handle) {
  uv_mutex_unlock(&handle->native);
}

static inline int mt_condition_create(mt_condition** out_condition) {
  if (out_condition != NULL) {
    *out_condition = NULL;
  }

  mt_condition* condition = (mt_condition*) malloc(sizeof(mt_condition));
  if (condition == NULL) {
    return UV_ENOMEM;
  }

  int status = uv_cond_init(&condition->native);
  if (status != 0) {
    free(condition);
    return status;
  }

  if (out_condition != NULL) {
    *out_condition = condition;
  }
  return 0;
}

static inline void mt_condition_destroy(mt_condition* handle) {
  if (handle == NULL) {
    return;
  }

  uv_cond_destroy(&handle->native);
  free(handle);
}

static inline void mt_condition_signal(mt_condition* handle) {
  uv_cond_signal(&handle->native);
}

static inline void mt_condition_broadcast(mt_condition* handle) {
  uv_cond_broadcast(&handle->native);
}

static inline void mt_condition_wait(mt_condition* handle, mt_mutex* mutex) {
  uv_cond_wait(&handle->native, &mutex->native);
}

static inline int mt_semaphore_create(unsigned int initial_value, mt_semaphore** out_semaphore) {
  if (out_semaphore != NULL) {
    *out_semaphore = NULL;
  }

  mt_semaphore* semaphore = (mt_semaphore*) malloc(sizeof(mt_semaphore));
  if (semaphore == NULL) {
    return UV_ENOMEM;
  }

  int status = uv_sem_init(&semaphore->native, initial_value);
  if (status != 0) {
    free(semaphore);
    return status;
  }

  if (out_semaphore != NULL) {
    *out_semaphore = semaphore;
  }
  return 0;
}

static inline void mt_semaphore_destroy(mt_semaphore* handle) {
  if (handle == NULL) {
    return;
  }

  uv_sem_destroy(&handle->native);
  free(handle);
}

static inline void mt_semaphore_post(mt_semaphore* handle) {
  uv_sem_post(&handle->native);
}

static inline void mt_semaphore_wait(mt_semaphore* handle) {
  uv_sem_wait(&handle->native);
}

static inline int mt_semaphore_try_wait(mt_semaphore* handle) {
  return uv_sem_trywait(&handle->native);
}

typedef struct mt_atomic_uint {
  unsigned int value;
} mt_atomic_uint;

static inline int mt_atomic_uint_create(mt_atomic_uint** out_atomic, unsigned int initial_value) {
  if (out_atomic != NULL) {
    *out_atomic = NULL;
  }

  mt_atomic_uint* atomic = (mt_atomic_uint*) malloc(sizeof(mt_atomic_uint));
  if (atomic == NULL) {
    return UV_ENOMEM;
  }

  atomic->value = initial_value;
  if (out_atomic != NULL) {
    *out_atomic = atomic;
  }
  return 0;
}

static inline void mt_atomic_uint_destroy(mt_atomic_uint* handle) {
  if (handle == NULL) {
    return;
  }

  free(handle);
}

static inline unsigned int mt_atomic_uint_load(mt_atomic_uint* atomic) {
  return __atomic_load_n(&atomic->value, __ATOMIC_SEQ_CST);
}

static inline void mt_atomic_uint_store(mt_atomic_uint* atomic, unsigned int new_value) {
  __atomic_store_n(&atomic->value, new_value, __ATOMIC_SEQ_CST);
}

static inline unsigned int mt_atomic_uint_fetch_add(mt_atomic_uint* atomic, unsigned int delta) {
  return __atomic_fetch_add(&atomic->value, delta, __ATOMIC_SEQ_CST);
}

static inline unsigned int mt_atomic_uint_fetch_sub(mt_atomic_uint* atomic, unsigned int delta) {
  return __atomic_fetch_sub(&atomic->value, delta, __ATOMIC_SEQ_CST);
}

static inline bool mt_atomic_uint_compare_exchange(mt_atomic_uint* atomic, unsigned int* expected, unsigned int desired) {
  return __atomic_compare_exchange_n(&atomic->value, expected, desired, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
}

#endif
