using UnityEngine;
using UnityEngine.UI;
using UnityEngine.InputSystem;

public class GearButtonScript : MonoBehaviour
{
    public Button button;
    public Transform characterUI;
    public GameObject gearMenuPrefab;
    public GameObject gearMenu;

    public void OnActivate()
    {
        if (gearMenu == null)
        {
            gearMenu = Instantiate(gearMenuPrefab, characterUI);
        }
        else
        {
            Destroy(gearMenu);
        }
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        characterUI = GameObject.Find("Character UI").transform;
        gearMenuPrefab = Resources.Load<GameObject>("Prefabs/Gear Menu");
    }

    void Update()
    {
        Keyboard keyboard = Keyboard.current;
        if (keyboard != null)
        {
            if (keyboard.oKey.wasPressedThisFrame)
            {
                OnActivate();
            }
        }
    }
}
