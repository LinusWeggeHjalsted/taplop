using UnityEngine;
using UnityEngine.UI;
using UnityEngine.InputSystem;

public class InventoryButtonScript : MonoBehaviour
{
    public Button button;
    public Transform characterUI;
    public GameObject inventoryMenuPrefab;
    public GameObject inventoryMenu;

    public void OnActivate()
    {
        if (inventoryMenu == null)
        {
            inventoryMenu = Instantiate(inventoryMenuPrefab, characterUI);
        }
        else
        {
            Destroy(inventoryMenu);
        }
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        characterUI = GameObject.Find("Character UI").transform;
        inventoryMenuPrefab = Resources.Load<GameObject>("Prefabs/Inventory Menu");
    }

    void Update()
    {
        Keyboard keyboard = Keyboard.current;
        if (keyboard != null)
        {
            if (keyboard.iKey.wasPressedThisFrame)
            {
                OnActivate();
            }
        }
    }
}
