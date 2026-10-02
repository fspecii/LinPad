#include <stdio.h>
#include <vulkan/vulkan.h>
int main(void) {
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_1};
    VkInstanceCreateInfo ci = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
    VkInstance inst;
    printf("create %d\n", vkCreateInstance(&ci, NULL, &inst)); fflush(stdout);
    uint32_t n = 4; VkPhysicalDevice pd[4];
    printf("enum %d n=%u\n", vkEnumeratePhysicalDevices(inst, &n, pd), n); fflush(stdout);
    for (uint32_t i = 0; i < n; i++) { VkPhysicalDeviceProperties p; vkGetPhysicalDeviceProperties(pd[i], &p); printf("dev %s\n", p.deviceName); }
    fflush(stdout);
    vkDestroyInstance(inst, NULL);
    printf("destroyed\n"); fflush(stdout);
    return 0;
}
