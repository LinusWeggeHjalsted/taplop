using UnityEngine;
using UnityEngine.EventSystems;

public class ItemSlotScript : MonoBehaviour, IDropHandler
{
    public GameObject player;
    public EntityScript playerScript;
    public Transform playerGear;
    public Transform playerInventory;
    public GameObject skillsPanel;
    public SkillsPanelScript skillsPanelScript;
    public string itemType = "";

    void Start()
    {
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<EntityScript>();
        playerGear = player.transform.Find("Gear");
        playerInventory = player.transform.Find("Inventory");
        skillsPanel = GameObject.Find("Skills Panel");
        skillsPanelScript = skillsPanel.GetComponent<SkillsPanelScript>();
    }

    public void SwapWithOtherSlot(GameObject otherItemSlot, GameObject otherItem)
    {
        ItemSlotScript otherItemSlotScript = otherItemSlot.GetComponent<ItemSlotScript>();
        InventoryItemScript otherItemScript = otherItem.GetComponent<InventoryItemScript>();
        GameObject ownItem = this.transform.GetChild(0).gameObject;
        InventoryItemScript ownItemScript = ownItem.GetComponent<InventoryItemScript>();
        bool otherItemMatches = (itemType == otherItemScript.itemType || itemType == "");
        bool ownItemMatches = (otherItemSlotScript.itemType == ownItemScript.itemType || otherItemSlotScript.itemType == "");
        if (otherItemMatches && ownItemMatches)
        {
            otherItem.transform.parent = this.transform;
            otherItemScript.currentParent = this.transform;
            otherItem.transform.localPosition = new Vector3(0, 0, 0);
            ownItem.transform.parent = otherItemSlot.transform;
            ownItemScript.currentParent = otherItemSlot.transform;
            ownItem.transform.localPosition = new Vector3(0, 0, 0);

            Transform playerInventory = playerScript.inventory;
            if (otherItemSlotScript.itemType != "")
            {
                GameObject actualOwnItem = ownItemScript.item;
                switch (otherItemSlotScript.itemType)
                {
                    case "Main Hand Weapon":
                        GameObject currentMainHandWeapon = playerScript.mainHandWeapon;
                        currentMainHandWeapon.transform.parent = playerInventory;
                        actualOwnItem.transform.parent = playerScript.mainHand;
                        break;
                    case "Off Hand Weapon":
                        GameObject currentOffHandWeapon = playerScript.offHandWeapon;
                        currentOffHandWeapon.transform.parent = playerInventory;
                        actualOwnItem.transform.parent = playerScript.offHand;
                        break;
                    case "Coat":
                        GameObject currentCoat = playerScript.coat;
                        currentCoat.transform.parent = playerInventory;
                        actualOwnItem.transform.parent = playerScript.body;
                        break;
                    case "Gloves":
                        GameObject currentGloves = playerScript.gloves;
                        currentGloves.transform.parent = playerInventory;
                        actualOwnItem.transform.parent = playerScript.hands;
                        break;
                    case "Boots":
                        GameObject currentBoots = playerScript.boots;
                        currentBoots.transform.parent = playerInventory;
                        actualOwnItem.transform.parent = playerScript.feet;
                        break;
                }
                skillsPanelScript.UpdateButtons();
            }

            if (itemType != "")
            {
                GameObject actualOtherItem = otherItemScript.item;
                switch (itemType)
                {
                    case "Main Hand Weapon":
                        GameObject currentMainHandWeapon = playerScript.mainHandWeapon;
                        currentMainHandWeapon.transform.parent = playerInventory;
                        actualOtherItem.transform.parent = playerScript.mainHand;
                        break;
                    case "Off Hand Weapon":
                        GameObject currentOffHandWeapon = playerScript.offHandWeapon;
                        currentOffHandWeapon.transform.parent = playerInventory;
                        actualOtherItem.transform.parent = playerScript.offHand;
                        break;
                    case "Coat":
                        GameObject currentCoat = playerScript.coat;
                        currentCoat.transform.parent = playerInventory;
                        actualOtherItem.transform.parent = playerScript.body;
                        break;
                    case "Gloves":
                        GameObject currentGloves = playerScript.gloves;
                        currentGloves.transform.parent = playerInventory;
                        actualOtherItem.transform.parent = playerScript.hands;
                        break;
                    case "Boots":
                        GameObject currentBoots = playerScript.boots;
                        currentBoots.transform.parent = playerInventory;
                        actualOtherItem.transform.parent = playerScript.feet;
                        break;
                }
                skillsPanelScript.UpdateButtons();
            }
        }
    }

    public void OnDrop(PointerEventData eventData)
    {
        GameObject droppedItem = eventData.pointerDrag;
        InventoryItemScript itemScript = droppedItem.GetComponent<InventoryItemScript>();
        if (this.transform.childCount > 0)
        {

            SwapWithOtherSlot(itemScript.currentParent.gameObject, droppedItem);
        }
        else
        {
            if (itemType != "")
            {
                if (itemScript.itemType == itemType)
                {
                    itemScript.currentParent = this.transform;
                    GameObject actualItem = itemScript.item;
                    ItemScript actualItemScript = actualItem.GetComponent<ItemScript>();
                    switch (itemType)
                    {
                        case "Main Hand Weapon":
                            actualItem.transform.parent = playerScript.mainHand;
                            break;
                        case "Off Hand Weapon":
                            actualItem.transform.parent = playerScript.offHand;
                            break;
                        case "Coat":
                            actualItem.transform.parent = playerScript.body;
                            break;
                        case "Gloves":
                            actualItem.transform.parent = playerScript.hands;
                            break;
                        case "Boots":
                            actualItem.transform.parent = playerScript.feet;
                            break;
                    }
                    skillsPanelScript.UpdateButtons();
                }
            }
            else
            {
                Transform originalItemSlot = itemScript.currentParent;
                ItemSlotScript originalItemSlotScript = originalItemSlot.GetComponent<ItemSlotScript>();
                if (originalItemSlotScript.itemType != "")
                {
                    GameObject actualItem = itemScript.item;
                    actualItem.transform.parent = playerScript.inventory;
                    skillsPanelScript.UpdateButtons();
                }
                itemScript.currentParent = this.transform;
            }
        }
    }
}
