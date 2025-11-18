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
        if (targetTransform.childCount > 0)
        {
            Transform currentItem = targetTransform.GetChild(0);
            currentItem.parent = playerScript.inventory;
        }
        selectedItem.transform.parent = targetTransform;
        // refresh open UI panels
        Transform characterUI = GameObject.Find("Character UI").transform;
        Transform gearUIPanel = characterUI.Find("Gear UI Panel(Clone)");
        if (gearUIPanel != null)
        {
            GearUIScript gearUIScript = gearUIPanel.GetComponent<GearUIScript>();
            gearUIScript.RefreshUI();
        }
        Transform inventoryUIPanel = characterUI.Find("Inventory UI Panel(Clone)");
        if (inventoryUIPanel != null)
        {
            InventoryUIScript inventoryUIScript = inventoryUIPanel.GetComponent<InventoryUIScript>();
            inventoryUIScript.RefreshUI();
        }
        // refresh skills panel in case weapons changed
        GameObject skillsPanel = GameObject.Find("Skills Panel");
        SkillsPanelScript skillsPanelScript = skillsPanel.GetComponent<SkillsPanelScript>();
        skillsPanelScript.UpdateButtons();
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
