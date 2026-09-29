package io.github.subhamsubhasispatra.idownloader.ui.pages.settings

import io.github.subhamsubhasispatra.idownloader.bridge.bridge
import io.github.subhamsubhasispatra.idownloader.model.Category
import io.github.subhamsubhasispatra.idownloader.model.CategoryState
import io.github.subhamsubhasispatra.idownloader.model.TaskError
import io.github.subhamsubhasispatra.idownloader.i18n.toTaskError
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class CategoryViewModel : ViewModel() {

    val state: StateFlow<CategoryState?> =
        bridge.observe<CategoryState>("categoryState")
            .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    private val _isSaving = MutableStateFlow(false)
    val isSaving = _isSaving.asStateFlow()

    private val _error = MutableStateFlow<TaskError?>(null)
    val error = _error.asStateFlow()

    fun setEnabled(isEnabled: Boolean) = write {
        bridge.invoke("setSetting", "isCategoryEnabled", isEnabled)
    }

    suspend fun add(category: Category) {
        bridge.invoke("addCategory", bridge.encode(category))
    }

    suspend fun update(category: Category) {
        bridge.invoke("updateCategory", bridge.encode(category))
    }

    fun remove(categoryId: String) = write {
        bridge.invoke("removeCategory", categoryId)
    }

    fun reset() = write {
        bridge.invoke("resetCategories")
    }

    fun setOrder(ids: List<String>) = write {
        bridge.invoke("reorderCategories", bridge.encode(ids))
    }

    private fun write(block: suspend () -> Unit) {
        if (_isSaving.value) return
        _isSaving.value = true
        viewModelScope.launch {
            try {
                block()
                _error.value = null
            } catch (e: CancellationException) { throw e }
            catch (failure: Exception) { _error.value = failure.toTaskError() }
            finally { _isSaving.value = false }
        }
    }
}
