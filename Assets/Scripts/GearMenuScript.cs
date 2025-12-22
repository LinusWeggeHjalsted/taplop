using UnityEngine;
using UnityEngine.UI;

public class GearMenuScript : MonoBehaviour
{
    public GameObject player;
    public PlayerCharacterScript playerScript;
    public GameObject inventoryItemPrefab;
    public Transform mainHandItemSlot;
    public Transform offHandItemSlot;
    public Transform neckItemSlot;
    public Transform bodyItemSlot;
    public Transform handsItemSlot;
    public Transform legsItemSlot;
    public Transform feetItemSlot;

    public void RefreshUI()
    {
        // clear existing items from all slots
        if (mainHandItemSlot.childCount > 0)
        {
            Destroy(mainHandItemSlot.GetChild(0).gameObject);
        }
        if (offHandItemSlot.childCount > 0)
        {
            Destroy(offHandItemSlot.GetChild(0).gameObject);
        }
        if (neckItemSlot.childCount > 0)
        {
            Destroy(neckItemSlot.GetChild(0).gameObject);
        }
        if (bodyItemSlot.childCount > 0)
        {
            Destroy(bodyItemSlot.GetChild(0).gameObject);
        }
        if (handsItemSlot.childCount > 0)
        {
            Destroy(handsItemSlot.GetChild(0).gameObject);
        }
        if (legsItemSlot.childCount > 0)
        {
            Destroy(legsItemSlot.GetChild(0).gameObject);
        }
        if (feetItemSlot.childCount > 0)
        {
            Destroy(feetItemSlot.GetChild(0).gameObject);
        }
        // then build inventory items
        GameObject mainHandWeapon = playerScript.mainHandWeapon;
        GameObject offHandWeapon = playerScript.offHandWeapon;
        GameObject amulet = playerScript.amulet;
        GameObject coat = playerScript.coat;
        GameObject gloves = playerScript.gloves;
        GameObject pants = playerScript.pants;
        GameObject boots = playerScript.boots;
        if (mainHandWeapon != null)
        {
            ItemScript mainHandWeaponScript = mainHandWeapon.GetComponent<ItemScript>();
            Sprite mainHandWeaponSprite = mainHandWeaponScript.GetSprite();
            GameObject mainHandItem = Instantiate(inventoryItemPrefab, mainHandItemSlot);
            InventoryItemScript mainHandItemScript = mainHandItem.GetComponent<InventoryItemScript>();
            mainHandItemScript.item = mainHandWeapon;
            Image mainHandItemImage = mainHandItem.GetComponent<Image>();
            mainHandItemImage.sprite = mainHandWeaponSprite;
        }
        if (offHandWeapon != null)
        {
            ItemScript offHandWeaponScript = offHandWeapon.GetComponent<ItemScript>();
            Sprite offHandWeaponSprite = offHandWeaponScript.GetSprite();
            GameObject offHandItem = Instantiate(inventoryItemPrefab, offHandItemSlot);
            InventoryItemScript offHandItemScript = offHandItem.GetComponent<InventoryItemScript>();
            offHandItemScript.item = offHandWeapon;
            Image offHandItemImage = offHandItem.GetComponent<Image>();
            offHandItemImage.sprite = offHandWeaponSprite;
        }
        if (amulet != null)
        {
            ItemScript amuletScript = amulet.GetComponent<ItemScript>();
            Sprite amuletSprite = amuletScript.GetSprite();
            GameObject amuletItem = Instantiate(inventoryItemPrefab, neckItemSlot);
            InventoryItemScript amuletItemScript = amuletItem.GetComponent<InventoryItemScript>();
            amuletItemScript.item = amulet;
            Image amuletItemImage = amuletItem.GetComponent<Image>();
            amuletItemImage.sprite = amuletSprite;
        }
        if (coat != null)
        {
            ItemScript coatScript = coat.GetComponent<ItemScript>();
            Sprite coatSprite = coatScript.GetSprite();
            GameObject coatItem = Instantiate(inventoryItemPrefab, bodyItemSlot);
            InventoryItemScript coatItemScript = coatItem.GetComponent<InventoryItemScript>();
            coatItemScript.item = coat;
            Image coatItemImage = coatItem.GetComponent<Image>();
            coatItemImage.sprite = coatSprite;
        }
        if (gloves != null)
        {
            ItemScript glovesScript = gloves.GetComponent<ItemScript>();
            Sprite glovesSprite = glovesScript.GetSprite();
            GameObject glovesItem = Instantiate(inventoryItemPrefab, handsItemSlot);
            InventoryItemScript glovesItemScript = glovesItem.GetComponent<InventoryItemScript>();
            glovesItemScript.item = gloves;
            Image glovesItemImage = glovesItem.GetComponent<Image>();
            glovesItemImage.sprite = glovesSprite;
        }
        if (pants != null)
        {
            ItemScript pantsScript = pants.GetComponent<ItemScript>();
            Sprite pantsSprite = pantsScript.GetSprite();
            GameObject pantsItem = Instantiate(inventoryItemPrefab, legsItemSlot);
            InventoryItemScript pantsItemScript = pantsItem.GetComponent<InventoryItemScript>();
            pantsItemScript.item = pants;
            Image pantsItemImage = pantsItem.GetComponent<Image>();
            pantsItemImage.sprite = pantsSprite;
        }
        if (boots != null)
        {
            ItemScript bootsScript = boots.GetComponent<ItemScript>();
            Sprite bootsSprite = bootsScript.GetSprite();
            GameObject bootsItem = Instantiate(inventoryItemPrefab, feetItemSlot);
            InventoryItemScript bootsItemScript = bootsItem.GetComponent<InventoryItemScript>();
            bootsItemScript.item = boots;
            Image bootsItemImage = bootsItem.GetComponent<Image>();
            bootsItemImage.sprite = bootsSprite;
        }
    }

    void Start()
    {
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<PlayerCharacterScript>();
        inventoryItemPrefab = Resources.Load<GameObject>("Prefabs/Inventory Item");
        Transform gearSlots = this.transform.Find("Gear Slots");
        Transform weapons = gearSlots.Find("Weapons");
        Transform mainHand = weapons.Find("Main Hand");
        Transform offHand = weapons.Find("Off Hand");
        Transform neck = gearSlots.Find("Neck");
        Transform body = gearSlots.Find("Body");
        Transform hands = gearSlots.Find("Hands");
        Transform legs = gearSlots.Find("Legs");
        Transform feet = gearSlots.Find("Feet");
        mainHandItemSlot = mainHand.GetChild(0);
        offHandItemSlot = offHand.GetChild(0);
        neckItemSlot = neck.GetChild(0);
        bodyItemSlot = body.GetChild(0);
        handsItemSlot = hands.GetChild(0);
        legsItemSlot = legs.GetChild(0);
        feetItemSlot = feet.GetChild(0);

        ItemSlotScript mainHandItemSlotScript = mainHandItemSlot.GetComponent<ItemSlotScript>();
        mainHandItemSlotScript.itemType = "Weapon";

        ItemSlotScript offHandItemSlotScript = offHandItemSlot.GetComponent<ItemSlotScript>();
        offHandItemSlotScript.itemType = "Weapon";

        ItemSlotScript neckItemSlotScript = neckItemSlot.GetComponent<ItemSlotScript>();
        neckItemSlotScript.itemType = "Amulet";

        ItemSlotScript bodyItemSlotScript = bodyItemSlot.GetComponent<ItemSlotScript>();
        bodyItemSlotScript.itemType = "Coat";

        ItemSlotScript handsItemSlotScript = handsItemSlot.GetComponent<ItemSlotScript>();
        handsItemSlotScript.itemType = "Gloves";

        ItemSlotScript legsItemSlotScript = legsItemSlot.GetComponent<ItemSlotScript>();
        legsItemSlotScript.itemType = "Pants";

        ItemSlotScript feetItemSlotScript = feetItemSlot.GetComponent<ItemSlotScript>();
        feetItemSlotScript.itemType = "Boots";

        RefreshUI();
    }
}
