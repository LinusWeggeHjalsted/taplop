using UnityEngine;

public class InventoryUIScript : MonoBehaviour
{
    GameObject itemSlotPrefab;

    void Start()
    {
        GameObject itemSlotPrefab = Resources.Load<GameObject>("Prefabs/Item Slot");
        for (int i = 0; i < 24; i++)
        {
            GameObject itemSlot = Instantiate(itemSlotPrefab, this.transform);
        }
    }
}
