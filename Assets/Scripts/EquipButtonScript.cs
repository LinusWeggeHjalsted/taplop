using UnityEngine;
using UnityEngine.UI;
using TMPro;
using System.Collections;

public class EquipButtonScript : MonoBehaviour
{
    public GameObject player;
    public PlayerCharacterScript playerScript;
    public Button button;
    public TMP_Text equipText;
    public Transform targetTransform; // will be set from context menu
    public GameObject selectedItem; // will be set from context menu

    public IEnumerator SetText(string text)
    {
        while (equipText == null)
        {
            yield return null;
        }
        equipText.text = text;
    }

    public void OnActivate()
    {
        if (targetTransform == null || selectedItem == null)
        {
            Debug.LogError("targetTransform or selectedItem not set yet");
            return;
        }
        ItemScript selectedItemScript = selectedItem.GetComponent<ItemScript>();
        int selectedItemPosition = selectedItemScript.inventoryPosition;
        GameObject currentItem = null;
        int currentItemPosition = 0;
        if (targetTransform.childCount > 0)
        {
            currentItem = targetTransform.GetChild(0).gameObject;
            currentItem.transform.parent = playerScript.inventory;
        }
        selectedItem.transform.parent = targetTransform;
        // swap inventory positions
        if (currentItem != null)
        {
            ItemScript currentItemScript = currentItem.gameObject.GetComponent<ItemScript>();
            currentItemPosition = currentItemScript.inventoryPosition;
            currentItemScript.inventoryPosition = selectedItemPosition;
        }
        selectedItemScript.inventoryPosition = currentItemPosition;
        // refresh open menus
        Transform characterUI = GameObject.Find("Character UI").transform;
        Transform gearMenu = characterUI.Find("Gear Menu(Clone)");
        if (gearMenu != null)
        {
            GearMenuScript gearMenuScript = gearMenu.GetComponent<GearMenuScript>();
            gearMenuScript.RefreshUI();
        }
        Transform inventoryMenu = characterUI.Find("Inventory Menu(Clone)");
        if (inventoryMenu != null)
        {
            InventoryMenuScript inventoryMenuScript = inventoryMenu.GetComponent<InventoryMenuScript>();
            inventoryMenuScript.RefreshUI();
        }
        // refresh skills panel in case weapons changed
        GameObject skillsPanel = GameObject.Find("Skills Panel");
        SkillBarScript skillBarScript = skillsPanel.GetComponent<SkillBarScript>();
        skillBarScript.UpdateButtons();
        // refresh health bar in case max health changed
        GameObject playerHealthBar = GameObject.Find("Player Health Bar");
        PlayerHealthBarScript playerHealthBarScript = playerHealthBar.GetComponent<PlayerHealthBarScript>();
        playerHealthBarScript.UpdateHealthBar();
        // restart move step in case speed changed
        GameObject turnLogic = GameObject.Find("Turn Logic");
        TurnLogicScript turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
        turnLogicScript.RestartPlayerMoveStep();
        // close context menu
        Transform canvas = GameObject.Find("Canvas").transform;
        Transform contextMenu = canvas.Find("Context Menu");
        if (contextMenu != null)
        {
            Destroy(contextMenu.gameObject);
        }
    }

    void Start()
    {
        equipText = this.transform.Find("Equip Button Text").gameObject.GetComponent<TMP_Text>();
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<PlayerCharacterScript>();
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
    }
}
